import Foundation
import Combine
import CryptoKit

struct HotwordModelFile: Sendable {
    let name: String
    let bytes: Int64
    let sha256: String
}
enum HotwordModelSpec {
    static let revision = "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"
    static let files = [
        HotwordModelFile(name:"model.safetensors",bytes:868628559,sha256:"0979f33d1bc58afcf696d13f57977644e7b11a6f0eec3e631d8e9463d18c0717"),
        HotwordModelFile(name:"config.json",bytes:784,sha256:"636d3e2a15e8914b8cf82b05cc2288a811f9bd93c3bf1afc00cab701a70b47c0"),
        HotwordModelFile(name:"tokenizer.json",bytes:7031673,sha256:"a8506e7111b80c6d8635951a02eab0f4e1a8e4e5772da83846579e97b16f61bf"),
        HotwordModelFile(name:"tokenizer_config.json",bytes:7308,sha256:"f7c61e32b7a17d19bf8e7037dcb74079a833e53ea9801f24008cac68458f03b7"),
        HotwordModelFile(name:"special_tokens_map.json",bytes:613,sha256:"76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        HotwordModelFile(name:"added_tokens.json",bytes:605,sha256:"58b54bbe36fc752f79a24a271ef66a0a0830054b4dfad94bde757d851968060b"),
        HotwordModelFile(name:"vocab.json",bytes:2776833,sha256:"ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        HotwordModelFile(name:"merges.txt",bytes:1671853,sha256:"8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5")]
    static var root: URL { ASRResources.root.deletingLastPathComponent().appendingPathComponent("HotwordLLM",isDirectory:true) }
    static func present(at root: URL = root) -> Bool {
        files.allSatisfy { item in
            let attrs = try? FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(item.name).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == item.bytes
        }
    }
    static func verify(_ root: URL) throws {
        for item in files {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(item.name)
            let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
            guard (attrs[.size] as? NSNumber)?.int64Value == item.bytes else { throw TranscriptionError.message("本地热词模型文件大小无效。") }
            let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount:1024*1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data:data) }
            guard hash.finalize().map({String(format:"%02x",$0)}).joined() == item.sha256 else { throw TranscriptionError.message("本地热词模型校验失败。") }
        }
    }
}
@MainActor final class HotwordModelStore: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var ready = HotwordModelSpec.present()
    private var task: Task<Void,Never>?
    func refresh() { ready = HotwordModelSpec.present() }
    func download() {
        guard !busy else { return }; busy = true; status = "正在下载本地提取模型…"
        task = Task { [weak self] in
            guard let self else { return }
            let manager = FileManager.default, parent = HotwordModelSpec.root.deletingLastPathComponent()
            let stage = parent.appendingPathComponent(".hotword-download-"+UUID().uuidString,isDirectory:true)
            defer { try? manager.removeItem(at:stage); self.busy = false; self.task = nil }
            do {
                try manager.createDirectory(at:stage,withIntermediateDirectories:true)
                for (index,item) in HotwordModelSpec.files.enumerated() {
                    try Task.checkCancellation(); self.status = "正在下载本地提取模型 · \(index+1)/\(HotwordModelSpec.files.count)…"
                    let raw = "https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit/resolve/\(HotwordModelSpec.revision)/\(item.name)"
                    let (temporary,response) = try await URLSession.shared.download(from:URL(string:raw)!)
                    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw TranscriptionError.message("模型下载失败。") }
                    try manager.moveItem(at:temporary,to:stage.appendingPathComponent(item.name))
                }
                self.status = "正在校验本地提取模型…"
                try await Task.detached(priority:.utility) { try HotwordModelSpec.verify(stage) }.value
                try Task.checkCancellation()
                if manager.fileExists(atPath:HotwordModelSpec.root.path) {
                    try manager.moveItem(at:HotwordModelSpec.root,to:parent.appendingPathComponent("HotwordLLM.previous-"+UUID().uuidString))
                }
                try manager.moveItem(at:stage,to:HotwordModelSpec.root)
                self.ready = true; self.status = "本地提取模型已就绪。"
            } catch { self.status = "模型下载或校验未完成：\(error.localizedDescription)" }
        }
    }
    func cancel() { task?.cancel() }
}
private final class HotwordProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock(); private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; let running = process.isRunning; lock.unlock(); if running { process.terminate() } }
    func run() throws {
        lock.lock(); if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw error }; lock.unlock()
        process.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else { throw TranscriptionError.message("本地候选词模型运行失败。") }
    }
}
actor HotwordLocalRuntime {
    static let shared = HotwordLocalRuntime()
    private var verified = false
    nonisolated static func configurationAvailable() -> Bool { HotwordModelSpec.present() && ASRResources.executable("qwen-asr") != nil }
    func generate(system: String, prompt: String) async throws -> String {
        guard let executable = ASRResources.executable("qwen-asr") else { throw TranscriptionError.message("安装包缺少本地模型引擎。") }
        if !verified { try await Task.detached(priority:.utility) { try HotwordModelSpec.verify(HotwordModelSpec.root) }.value; verified = true }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TalkTuck-hotwords-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let input = directory.appendingPathComponent("input.json"), output = directory.appendingPathComponent("output.json")
        try JSONSerialization.data(withJSONObject:["system":system,"prompt":prompt]).write(to:input,options:.atomic)
        let child = HotwordProcess(); child.process.executableURL = executable
        child.process.arguments = ["--extract-hotwords",HotwordModelSpec.root.path,input.path,output.path]
        child.process.standardOutput = FileHandle.nullDevice; child.process.standardError = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try await Task.detached(priority:.utility) { try child.run() }.value
        } onCancel: { child.cancel() }
        guard let result = try JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:String], let text = result["text"] else { throw TranscriptionError.message("本地候选词模型响应无效。") }
        return text
    }
}
