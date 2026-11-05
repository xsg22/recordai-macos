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
        if ready { status = "语音模型已下载，可离线使用。"; progress = 1; error = nil }
        else { status = "语音模型尚未就绪，请下载或重试校验。"; progress = 0 }
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
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var store: ASRModelStore
    var close: (() -> Void)? = nil
    var body: some View {
        ASRModelDownloadPanel(ready: store.ready, busy: store.busy, progress: store.progress,
            status: store.status, error: store.error, totalBytes: store.manifest?.totalBytes,
            download: { store.download() }, cancel: { store.cancel() }, close: close)
    }
}

/// Pure presentation shared by the real download flow and isolated UI state previews.
struct ASRModelDownloadPanel: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let ready: Bool
    let busy: Bool
    let progress: Double
    let status: String
    let error: String?
    let totalBytes: Int64?
    let download: () -> Void
    let cancel: () -> Void
    var close: (() -> Void)? = nil
    private let models = [("Paraformer", "中英双语实时转写", "waveform"),
                          ("Qwen3-ASR", "会后定稿", "text.alignleft"),
                          ("Silero VAD", "语音检测", "waveform.path"),
                          ("Sortformer / 逐词对齐", "发言人与时间对齐", "person.2")]
    var body: some View {
        VStack(alignment: .leading, spacing: busy ? 17 : error == nil ? 18 : 16) {
            HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.text(ready ? "语音模型已就绪" : "下载语音模型")).font(.system(size: 23, weight: .semibold))
                Text(L10n.text("完成一次下载后，即可在本机离线转录。"))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
            }
                Spacer()
                if let close { Button(L10n.text("完成"), action: close).keyboardShortcut(.cancelAction) }
            }.padding(.bottom, 16)
            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                    HStack(spacing: 12) {
                        Image(systemName: model.2).font(.system(size: 19)).foregroundStyle(TalkTuckTheme.accent)
                            .frame(width: 38, height: 38).background(TalkTuckTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text(model.0)).font(AppTypography.body.weight(.medium))
                            Text(L10n.text(model.1)).font(AppTypography.secondary).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel(L10n.text("已下载")) }
                        else {
                            Text(L10n.text(busy ? "等待校验" : "本地运行")).font(.system(size: 12)).foregroundStyle(TalkTuckTheme.muted)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .background(TalkTuckTheme.quiet, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }.padding(.vertical, 14.5)
                    if index < models.count - 1 { Divider() }
                }
            }
            if busy {
                TalkTuckCard(quiet: true) {
                    VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(L10n.text("正在下载 · \(Int(progress * 100))%")).font(AppTypography.body.weight(.medium)).monospacedDigit()
                        Spacer()
                        if let totalBytes {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(Double(totalBytes) * max(0, min(1, progress))), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                                .font(AppTypography.secondary).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: progress).tint(TalkTuckTheme.accent)
                    Text(L10n.text(status)).font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("取消下载"), action: cancel)
                    }.frame(maxWidth: .infinity, minHeight: 161, alignment: .leading)
                }
            } else if let error {
                TalkTuckInfo(text: L10n.text(error + " 已完成文件会保留，可重试继续下载。"), warning: true)
            } else {
                TalkTuckInfo(text: L10n.text(ready ? status : "根据地区自动选择下载源，逐文件校验后才启用模型。录音和文字不会上传。"))
            }
            if error == nil { Spacer(minLength: 0) }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    if let totalBytes { Text(L10n.text("下载大小：" + ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))) }
                    Text(L10n.text("保存在本机数据目录，升级后继续复用。"))
                }.font(AppTypography.secondary).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !ready && !busy { Button(L10n.text(error == nil ? "下载语音模型" : "重试下载"), action: download).buttonStyle(TalkTuckPrimaryButtonStyle()) }
                if busy, let close { Button(L10n.text("后台继续下载"), action: close).buttonStyle(TalkTuckPrimaryButtonStyle()) }
            }
        }.frame(maxWidth: .infinity, minHeight: busy ? 655 : error == nil ? 509 : 485, alignment: .topLeading).buttonStyle(TalkTuckSecondaryButtonStyle())
    }
}
