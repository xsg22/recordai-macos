import CryptoKit
import Foundation

@main struct OptionalModelSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohear-optional-model-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "cohear-optional-model-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let spec = OptionalModelSpec.all[0]
        let text = Data("GGUF-test-text".utf8), vision = Data("GGUF-test-vision".utf8)
        func file(_ name: String, _ data: Data) -> [String: Any] {
            ["rfilename": name, "lfs": ["size": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]]
        }
        let object: [String: Any] = ["sha": String(repeating: "a", count: 40), "siblings": [file("gemma-3-4b-it-Q4_K_M.gguf", text), file("mmproj-model-f16.gguf", vision)]]
        let manifest = try OptionalModelCatalog.parse(JSONSerialization.data(withJSONObject: object), spec: spec)
        precondition(manifest.totalBytes == text.count + vision.count)
        precondition(OptionalModelCatalog.downloadURL(manifest.files[0], manifest: manifest).path.contains(manifest.revision))
        let directory = root.appendingPathComponent(spec.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try text.write(to: directory.appendingPathComponent(manifest.files[0].name))
        let store = OptionalModelStore(root: root, defaults: defaults)
        await store.refreshInstalled()
        precondition(store.installed.isEmpty && store.activeID == nil, "缺图片模型不能启用")
        try vision.write(to: directory.appendingPathComponent(manifest.files[1].name))
        await store.refreshInstalled()
        precondition(store.installed.contains(spec.id) && store.activeID == nil)
        store.chooseInstalled(spec.id)
        precondition(store.activeID == spec.id)
        let restored = OptionalModelStore(root: root, defaults: defaults)
        await restored.refreshInstalled()
        precondition(restored.activeID == spec.id)
        store.disable(); precondition(store.activeID == nil)
        try Data(repeating: 0, count: vision.count).write(to: directory.appendingPathComponent(manifest.files[1].name))
        await restored.refreshInstalled()
        precondition(restored.installed.isEmpty && restored.activeID == nil, "损坏文件必须禁用")
        var bad = object
        bad["siblings"] = [file("../escape-Q4_K_M.gguf", text), file("mmproj-model-f16.gguf", vision)]
        do { _ = try OptionalModelCatalog.parse(JSONSerialization.data(withJSONObject: bad), spec: spec); fatalError("不允许目录逃逸") } catch is OptionalModelError { }
        bad["siblings"] = [file("model-Q4_K_M.gguf", text)]
        do { _ = try OptionalModelCatalog.parse(JSONSerialization.data(withJSONObject: bad), spec: spec); fatalError("不允许缺少配套文件") } catch is OptionalModelError { }
        print("PASS: 固定版本/配套模型/路径与SHA校验/缺文件禁用/默认关闭/选择恢复/损坏禁用。仅临时小文件，没有下载真实模型。")
    }
}
