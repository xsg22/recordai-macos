import AppKit
import Foundation
import SwiftUI

@MainActor
final class OptionalModelStore: ObservableObject {
    @Published var selectedID = OptionalModelSpec.all[0].id
    @Published var licenseAccepted = false
    @Published private(set) var installed = Set<String>()
    @Published private(set) var activeID: String?
    @Published private(set) var busy = false
    @Published private(set) var downloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var status = "辅助模型默认关闭。选择后点击下载。"
    @Published var error: String?
    let root: URL
    private var task: Task<Void, Never>?
    private var downloader: OptionalModelDownload?
    private var generation = UUID()
    private let defaults: UserDefaults
    private let preferenceKey = "optionalGemma.activeModel.v1"
    var selected: OptionalModelSpec { OptionalModelSpec.all.first { $0.id == selectedID } ?? OptionalModelSpec.all[0] }
    var availableMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoHearTranscribe/AuxiliaryModels", isDirectory: true)
        self.defaults = defaults
        // 不在构造期联网或读取数GB权重，设置窗口出现后再验证已有文件。
    }
    func refreshInstalled() async {
        guard !busy else { return }
        busy = true; status = "正在核验本机已下载模型…"
        defer { busy = false }
        var valid = Set<String>()
        for spec in OptionalModelSpec.all {
            let directory = root.appendingPathComponent(spec.id, isDirectory: true)
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(OptionalModelManifest.self, from: data),
                  manifest.modelID == spec.id, manifest.repository == spec.repository,
                  manifest.files.count == 2 else { continue }
            let checked = (try? await Task.detached(priority: .utility) {
                try manifest.files.allSatisfy { file in
                    guard file.name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return false }
                    return try OptionalModelIntegrity.verify(directory.appendingPathComponent(file.name), file: file)
                }
            }.value) ?? false
            if checked { valid.insert(spec.id) }
        }
        installed = valid
        if let desired = defaults.string(forKey: preferenceKey), valid.contains(desired) { activeID = desired }
        else { activeID = nil; defaults.removeObject(forKey: preferenceKey) }
        status = installed.isEmpty ? "辅助模型默认关闭。选择后点击下载。" : "已核验 \(installed.count) 个模型；可选择默认辅助模型。"
    }

    func downloadSelected() {
        guard !busy, licenseAccepted else { return }
        let spec = selected
        guard availableMemoryGB >= 8 else { error = "当前内存不足 8 GB，不建议安装此多模态模型。"; return }
        busy = true; downloading = true; progress = 0; completedBytes = 0; totalBytes = 0; error = nil
        let id = UUID(); generation = id
        status = "正在获取 \(spec.name) 的下载清单…"
        task = Task { [self] in
            defer { busy = false; downloading = false; downloader = nil; task = nil }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let directory = root.appendingPathComponent(spec.id, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let manifest = try await OptionalModelCatalog.resolve(spec, onFallback: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.status = "Hugging Face暂不可用，正在读取ModelScope备用清单…"
                    }
                })
                try Task.checkCancellation()
                totalBytes = manifest.totalBytes
                let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                // 所有文件的安全空间预算，不依赖下载前的估算文案。
                if let capacity, capacity < manifest.totalBytes + 512 * 1024 * 1024 {
                    throw OptionalModelError.message("磁盘空间不足，请至少预留 \(ByteCountFormatter.string(fromByteCount: manifest.totalBytes + 512 * 1024 * 1024, countStyle: .file))。")
                }
                try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
                var verifiedBytes: Int64 = 0
                var modelScopeBackup: OptionalModelManifest?
                for file in manifest.files {
                    try Task.checkCancellation()
                    let destination = directory.appendingPathComponent(file.name)
                    let alreadyValid = try await Task.detached(priority: .utility) { try OptionalModelIntegrity.verify(destination, file: file) }.value
                    if alreadyValid { verifiedBytes += file.bytes; completedBytes = verifiedBytes; continue }
                    let partial = directory.appendingPathComponent(file.name + ".partial")
                    defer { try? FileManager.default.removeItem(at: partial) }
                    let preferred = modelScopeBackup ?? manifest
                    status = "正在从\(preferred.source.displayName)下载 \(file.name)…"
                    let previousBytes = verifiedBytes
                    let total = manifest.totalBytes
                    @MainActor func newDownload() -> OptionalModelDownload {
                        let job = OptionalModelDownload(destination: partial, expectedBytes: file.bytes) { [weak self] bytes in
                            Task { @MainActor in
                                guard let self, self.generation == id else { return }
                                self.completedBytes = previousBytes + bytes
                                self.progress = min(0.99, Double(self.completedBytes) / Double(total))
                            }
                        }
                        downloader = job
                        return job
                    }
                    do {
                        _ = try await newDownload().fetch(OptionalModelCatalog.downloadURL(file, manifest: preferred))
                    } catch {
                        guard preferred.source == .huggingFace, OptionalModelCatalog.shouldFallback(error) else { throw error }
                        try Task.checkCancellation()
                        status = "Hugging Face文件下载失败，正在核对ModelScope备用文件…"
                        if modelScopeBackup == nil { modelScopeBackup = try await OptionalModelCatalog.resolveModelScope(spec) }
                        guard let backup = modelScopeBackup else { throw OptionalModelError.message("备用模型清单不可用。") }
                        try OptionalModelCatalog.assertSameFiles(manifest, backup)
                        completedBytes = previousBytes
                        progress = Double(previousBytes) / Double(total)
                        status = "已确认文件一致，切换ModelScope下载 \(file.name)…"
                        _ = try await newDownload().fetch(OptionalModelCatalog.downloadURL(file, manifest: backup))
                    }
                    try Task.checkCancellation()
                    status = "正在校验 \(file.name)…"
                    let valid = try await Task.detached(priority: .utility) { try OptionalModelIntegrity.verify(partial, file: file) }.value
                    try Task.checkCancellation()
                    guard valid else { throw OptionalModelError.message("文件校验失败，未启用模型。请重试下载。") }
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: partial, to: destination)
                    verifiedBytes += file.bytes; completedBytes = verifiedBytes
                }
                installed.insert(spec.id); activeID = spec.id
                defaults.set(spec.id, forKey: preferenceKey)
                progress = 1; status = "模型文件下载并校验完成，已设为默认辅助模型。"
            } catch is CancellationError {
                status = "已取消下载。已校验文件会保留，重试时复用。"
            } catch let network as URLError where network.code == .cancelled {
                status = "已取消下载。已校验文件会保留，重试时复用。"
            } catch {
                self.error = (error as? OptionalModelError)?.localizedDescription ?? "模型下载未完成，请检查网络、访问权限和磁盘空间后重试。"
                status = "下载未完成，模型没有启用，可重试。"
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); downloader?.cancel() }
    func chooseInstalled(_ id: String) {
        guard installed.contains(id), !busy else { return }
        activeID = id; defaults.set(id, forKey: preferenceKey)
        status = "已选择默认辅助模型；权重保留在本机。"
    }
    func disable() {
        guard !busy else { return }
        activeID = nil; defaults.removeObject(forKey: preferenceKey)
        status = "辅助模型已关闭。已下载文件会保留。"
    }
    func removeSelected() {
        guard !busy else { return }
        let id = selectedID
        let directory = root.appendingPathComponent(id, isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
            installed.remove(id)
            if activeID == id { disable() }
            status = "模型文件已移入废纸篓。"
        } catch { self.error = "无法移除模型文件：\(error.localizedDescription)" }
    }
    func revealFiles() {
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); NSWorkspace.shared.open(root) }
        catch { self.error = "无法打开模型目录。" }
    }
}
