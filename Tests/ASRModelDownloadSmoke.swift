import CryptoKit
import Foundation

@main struct ASRModelDownloadSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recordai-models-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("model-fixture".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let source = try Data(contentsOf: URL(fileURLWithPath: "Resources/ASRModels.json"))
        var fields = try JSONSerialization.jsonObject(with: source) as! [String: Any]
        var files = fields["files"] as! [[String: Any]]
        for index in files.indices { files[index]["bytes"] = payload.count; files[index]["sha256"] = hash }
        fields["files"] = files
        let manifest = try ASRModelManifest.parse(JSONSerialization.data(withJSONObject: fields))
        precondition(manifest.files[0].downloadURLs(inChina: true)[0].host == "modelscope.cn", "中国地区优先国内源")
        precondition(manifest.files[0].downloadURLs(inChina: false)[0].host == "huggingface.co", "海外地区优先海外源")
        precondition(!manifest.isInstalled(at: root), "无校验回执不能加载模型")
        for file in manifest.files {
            let path = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: path)
        }
        let store = ASRModelStore(root: root, manifest: manifest)
        precondition(!store.ready, "部分下载或未校验文件不能启用")
        store.download()
        for _ in 0..<500 where store.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(store.ready && store.error == nil && store.progress == 1, "已有正确文件应直接校验复用，无需联网")
        precondition(ASRModelStore(root: root, manifest: manifest).ready, "重新打开可直接识别已下载模型")
        let first = manifest.files[0]
        try Data("broken".utf8).write(to: root.appendingPathComponent(first.path))
        precondition(!manifest.isInstalled(at: root), "不完整文件不能加载")
        store.refresh()
        precondition(!store.ready, "模型文件丢失或损坏后重新进入下载流程")
        let corrupt = try OptionalModelIntegrity.verify(root.appendingPathComponent(first.path), file: first.integrity)
        precondition(!corrupt, "损坏文件必须校验失败")
        var escaped = files; escaped[0]["path"] = "../escape"
        fields["files"] = escaped
        do { _ = try ASRModelManifest.parse(JSONSerialization.data(withJSONObject: fields)); preconditionFailure("拒绝路径逃逸") }
        catch is OptionalModelError { }
        files[0]["url"] = "http://modelscope.cn/insecure"
        fields["files"] = files
        do { _ = try ASRModelManifest.parse(JSONSerialization.data(withJSONObject: fields)); preconditionFailure("拒绝不安全下载源") }
        catch is OptionalModelError { }
        files[0]["url"] = "https://modelscope.cn/secure"
        files[0]["overseasURL"] = "http://huggingface.co/insecure"
        fields["files"] = files
        do { _ = try ASRModelManifest.parse(JSONSerialization.data(withJSONObject: fields)); preconditionFailure("备用源同样需要HTTPS") }
        catch is OptionalModelError { }
        let cancelled = ASRModelStore(root: root.appendingPathComponent("cancelled"), manifest: manifest)
        cancelled.download(); cancelled.cancel()
        for _ in 0..<100 where cancelled.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!cancelled.ready && !cancelled.busy, "取消不能启用半成品")
        print("PASS: 模型清单边界、校验回执、缓存复用、损坏拒绝、取消不启用。仅临时小文件，无权重下载。")
    }
}
