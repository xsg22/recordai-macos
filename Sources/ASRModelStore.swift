import Foundation
import SwiftUI

struct ASRModelManifest: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
        let url: URL
        let overseasURL: URL
        var integrity: OptionalModelFile { .init(name: path, bytes: bytes, sha256: sha256) }
        func downloadURLs(inChina: Bool) -> [URL] { inChina ? [url, overseasURL] : [overseasURL, url] }
    }
    let version: Int
    let files: [File]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "ASRModels", withExtension: "json") else {
            throw OptionalModelError.message("缺少语音模型下载清单，请重新安装 App。")
        }
        return try parse(Data(contentsOf: url))
    }
    static func parse(_ data: Data) throws -> Self {
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        let groups: Set<String> = ["Paraformer", "Qwen3ASR", "Sortformer", "QwenAligner"]
        guard manifest.version == 1, !manifest.files.isEmpty,
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              manifest.files.allSatisfy({ file in
                  let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
                  return parts.count == 2 && groups.contains(String(parts[0])) && parts[1] != "." && parts[1] != ".."
                      && parts[1].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
                      && file.bytes > 0 && file.bytes < 16_000_000_000
                      && file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                      && file.url.scheme == "https" && file.url.host == "modelscope.cn"
                      && file.overseasURL.scheme == "https" && ["huggingface.co", "raw.githubusercontent.com"].contains(file.overseasURL.host ?? "")
              }) else { throw OptionalModelError.message("语音模型清单无效。") }
        return manifest
    }
    private var receipt: Data {
        Data(files.sorted { $0.path < $1.path }.map { "\($0.path) \($0.bytes) \($0.sha256)" }.joined(separator: "\n").utf8)
    }
    func isInstalled(at root: URL) -> Bool {
        guard (try? Data(contentsOf: root.appendingPathComponent(".verified"))) == receipt else { return false }
        return files.allSatisfy { file in
            guard let values = try? root.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true && values.fileSize == Int(file.bytes)
        }
    }
    func saveReceipt(at root: URL) throws { try receipt.write(to: root.appendingPathComponent(".verified"), options: .atomic) }
}

@MainActor final class ASRModelStore: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "首次使用需下载语音模型，下载后可离线转录。"
    @Published private(set) var error: String?
    let root: URL
    let manifest: ASRModelManifest?
    private var task: Task<Void, Never>?
    private var downloader: OptionalModelDownload?
    private var transferID = UUID()

    init(root: URL = ASRResources.root, manifest: ASRModelManifest? = try? ASRModelManifest.load()) {
        self.root = root; self.manifest = manifest
        ready = manifest?.isInstalled(at: root) == true
        if ready { status = "语音模型已下载，可离线使用。"; progress = 1 }
    }
    func refresh() {
        guard !busy else { return }
        ready = manifest?.isInstalled(at: root) == true
        if !ready { status = "语音模型尚未就绪，请下载或重试校验。"; progress = 0 }
    }
    func download() {
        guard !busy else { return }
        guard let manifest else { error = "无法读取语音模型下载清单，请重新安装 App。"; return }
        busy = true; ready = false; error = nil; progress = 0
        task = Task { [self] in
            defer { busy = false; task = nil; downloader = nil; transferID = UUID() }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var completed: Int64 = 0
                for file in manifest.files {
                    try Task.checkCancellation()
                    let target = root.appendingPathComponent(file.path)
                    for path in [target.deletingLastPathComponent(), target] {
                        if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                            throw OptionalModelError.message("模型目录不能包含符号链接。")
                        }
                    }
                    status = "正在校验 \(file.path)…"
                    let valid = try await Task.detached(priority: .utility) {
                        try OptionalModelIntegrity.verify(target, file: file.integrity)
                    }.value
                    if !valid {
                        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                        if let capacity, capacity < file.bytes + 512 * 1024 * 1024 {
                            throw OptionalModelError.message("磁盘空间不足，请释放空间后重试。")
                        }
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let partial = target.appendingPathExtension("partial")
                        defer { try? FileManager.default.removeItem(at: partial) }
                        let previous = completed
                        let total = manifest.totalBytes
                        var failure: Error?
                        let urls = file.downloadURLs(inChina: Locale.current.region?.identifier == "CN")
                        for (index, url) in urls.enumerated() {
                            try Task.checkCancellation()
                            let id = UUID(); transferID = id
                            let download = OptionalModelDownload(destination: partial, expectedBytes: file.bytes) { [weak self] bytes in
                                Task { @MainActor in
                                    guard let self, self.busy, self.transferID == id else { return }
                                    self.progress = min(0.99, Double(previous + bytes) / Double(total))
                                }
                            }
                            downloader = download
                            let source = url.host == "modelscope.cn" ? "国内 ModelScope" : url.host == "huggingface.co" ? "海外 Hugging Face" : "海外官方源"
                            status = "\(index == 0 ? "正在下载" : "已切换备用来源") · \(source) · \(file.path)"
                            do {
                                _ = try await download.fetch(url)
                                try Task.checkCancellation()
                                status = "正在校验 \(file.path)…"
                                guard try await Task.detached(priority: .utility, operation: {
                                    try OptionalModelIntegrity.verify(partial, file: file.integrity)
                                }).value else { throw OptionalModelError.message("\(file.path) 校验失败。") }
                                failure = nil
                                break
                            } catch {
                                try Task.checkCancellation()
                                failure = error
                                transferID = UUID()
                                progress = Double(previous) / Double(total)
                            }
                        }
                        if let failure { throw failure }
                        try Task.checkCancellation()
                        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: partial) }
                        else { try FileManager.default.moveItem(at: partial, to: target) }
                    }
                    completed += file.bytes; progress = Double(completed) / Double(manifest.totalBytes)
                }
                try Task.checkCancellation()
                try manifest.saveReceipt(at: root)
                ready = true; status = "语音模型已下载并通过校验，可离线使用。"
            } catch is CancellationError { status = "下载已暂停，已完成的文件会保留。" }
            catch { self.error = error.localizedDescription; status = "下载未完成，点击重试可复用已校验文件。" }
        }
    }
    func cancel() { task?.cancel(); downloader?.cancel() }
}

struct ASRModelSetupView: View {
    @ObservedObject var store: ASRModelStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("语音模型", systemImage: "arrow.down.circle").font(.headline)
            Text(store.status).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            if let manifest = store.manifest {
                Text("Paraformer · Qwen ASR · Sortformer · 逐词对齐\n下载大小：\(ByteCountFormatter.string(fromByteCount: manifest.totalBytes, countStyle: .file))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("中国地区优先国内源，其他地区优先海外源；下载失败自动切换，文件统一校验。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if store.busy { ProgressView(value: store.progress); Text("\(Int(store.progress * 100))%") .monospacedDigit() }
            if let error = store.error { Text(error).font(.system(size: 13)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if store.busy { Button("取消下载") { store.cancel() } }
                else if !store.ready { Button(store.error == nil ? "下载语音模型" : "重试下载") { store.download() }.buttonStyle(.borderedProminent) }
            }
            Text("模型保存在本机数据目录，升级 App 后继续复用。下载只获取模型文件，录音和文字不会上传。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
