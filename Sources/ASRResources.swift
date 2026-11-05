import Foundation

/// 权重下载到稳定的数据目录，升级 App 不重复下载。
enum ASRResources {
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CoHearTranscribe/Models/ASR", isDirectory: true) }
    static var qwen: URL? { checked("Qwen3ASR", files: ["config.json", "model.safetensors", "vocab.json", "merges.txt"]) }
    static var sortformer: URL? { checked("Sortformer", files: ["config.json", "model.safetensors"]) }
    static var aligner: URL? { checked("QwenAligner", files: ["config.json", "model.safetensors", "vocab.json", "merges.txt"]) }
    static var paraformer: URL? { checked("Paraformer", files: ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt", "silero_vad.onnx"]) }
    static let liveHotwordModelKey = "LiveHotwordModelDirectory"
    static func validLiveHotwordModel(_ url: URL) -> Bool {
        let sizes = ["encoder.onnx": 155278641, "decoder.onnx": 11309084, "joiner.onnx": 2581422, "tokens.txt": 58806, "bpe.vocab": 69594]
        guard FileManager.default.isWritableFile(atPath: url.path) else { return false }
        return sizes.allSatisfy { name, size in
            let file = url.appendingPathComponent(name)
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else { return false }
            return values.isRegularFile == true && values.fileSize == size && FileManager.default.isReadableFile(atPath: file.path)
        }
    }
    static var liveHotwordModel: URL? {
        guard let path = UserDefaults.standard.string(forKey: liveHotwordModelKey), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return validLiveHotwordModel(url) ? url : nil
    }
    static func executable(_ name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Engine/ASR/" + name),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
    private static func checked(_ directory: String, files: [String]) -> URL? {
        let url = root.appendingPathComponent(directory, isDirectory: true)
        guard let manifest = try? ASRModelManifest.load(),
              manifest.isInstalled(at: root),
              files.allSatisfy({ FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }) else { return nil }
        return url
    }
}
