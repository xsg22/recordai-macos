import CryptoKit
import Foundation

@main struct ASRSourceFallbackSmoke {
    @MainActor static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recordai-source-fallback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("model-fixture".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let inChina = Locale.current.region?.identifier == "CN"
        for failure in ["bad", "corrupt", "both-fail"] {
            let first = base.appendingPathComponent(failure == "both-fail" ? "bad" : failure)
            let backup = base.appendingPathComponent(failure == "both-fail" ? "bad" : "model")
            let file = ASRModelManifest.File(path: "Qwen3ASR/config.json", bytes: Int64(payload.count), sha256: hash,
                url: inChina ? first : backup, overseasURL: inChina ? backup : first)
            let directory = root.appendingPathComponent(failure)
            let manifest = ASRModelManifest(version: 1, files: [file])
            let store = ASRModelStore(root: directory, manifest: manifest)
            store.download()
            for _ in 0..<1000 where store.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(!store.busy)
            if failure == "both-fail" {
                precondition(!store.ready && store.error != nil && !manifest.isInstalled(at: directory), "两源失败不能启用")
            } else {
                let received = try Data(contentsOf: directory.appendingPathComponent(file.path))
                precondition(store.ready && store.error == nil && received == payload, "HTTP错误或校验失败后必须切换并验证备用源")
            }
        }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("stats"))
        let counts = try JSONDecoder().decode([String: Int].self, from: data)
        precondition(counts["bad"] == 3 && counts["corrupt"] == 1 && counts["model"] == 2, "必须实际请求主源和备用源")
        print("PASS: 真实本机HTTP下载的500回退、SHA256不匹配回退、双源失败不启用。无真实权重下载。")
    }
}
