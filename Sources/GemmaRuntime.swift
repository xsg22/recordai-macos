import Darwin
import Foundation

private final class GemmaNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class GemmaProcessLifetime: @unchecked Sendable {
    static let shared = GemmaProcessLifetime()
    private let lock = NSLock()
    private var child: Process?
    func register(_ value: Process?) { lock.lock(); child = value; lock.unlock() }
    func terminate() {
        lock.lock(); let value = child; child = nil; lock.unlock()
        if let value, value.isRunning { value.terminate() }
    }
}

/// 只运行App内置引擎，HTTP仅监听127.0.0.1且每次启动用随机鉴权。不会把会议传到模型供应商。
actor GemmaRuntime {
    static let shared = GemmaRuntime()
    nonisolated static func terminateBackgroundProcess() { GemmaProcessLifetime.shared.terminate() }
    private let root: URL
    private let defaults: UserDefaults
    private let executableOverride: URL?
    private var process: Process?
    private var modelPath: URL?
    private var serverURL: URL?
    private var apiKey = ""
    private var workDirectory: URL?
    private var log: FileHandle?
    private var generation: UUID?
    private var cancelledGeneration: UUID?
    private var verifiedManifest: Data?
    private var verifiedModel: URL?
    private var idleTask: Task<Void, Never>?
    private let session: URLSession

    init(modelDirectory: URL? = nil, defaults: UserDefaults = .standard, executable: URL? = nil) {
        root = modelDirectory ?? Self.defaultModelDirectory
        self.defaults = defaults; executableOverride = executable
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: GemmaNoRedirect(), delegateQueue: nil)
    }
    private nonisolated static var defaultModelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoHearTranscribe/AuxiliaryModels", isDirectory: true)
    }
    nonisolated static func configurationAvailable() -> Bool {
        guard let id = UserDefaults.standard.string(forKey: "optionalGemma.activeModel.v1"),
              OptionalModelSpec.all.contains(where: { $0.id == id }) else { return false }
        let directory = defaultModelDirectory.appendingPathComponent(id)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(OptionalModelManifest.self, from: data), manifest.modelID == id else { return false }
        return manifest.files.contains { $0.name.hasSuffix("Q4_K_M.gguf") && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.name).path) }
    }

    func generate(system: String, prompt: String, onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        guard generation == nil else { throw OptionalModelError.message("本地Gemma正在处理上一项任务，请稍候。") }
        guard system.count + prompt.count <= 7000 else { throw OptionalModelError.message("会议资料超出单次本地上下文，请缩小范围后重试。") }
        let id = UUID(); generation = id; cancelledGeneration = nil; idleTask?.cancel(); idleTask = nil
        defer {
            if generation == id {
                generation = nil
                cancelledGeneration = nil
                idleTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 180_000_000_000); try Task.checkCancellation() } catch { return }
                    await self?.releaseIfIdle()
                }
            }
        }
        return try await withTaskCancellationHandler {
            do {
                let model = try await resolveModel()
                try checkGeneration(id)
                try await ensureServer(model: model, id: id)
                try checkGeneration(id)
                guard let serverURL else { throw OptionalModelError.message("本地模型服务未就绪。") }
                // Gemma聊天模板不接受system角色，合并为一个user消息。
                var request = authorizedRequest(serverURL.appendingPathComponent("v1/chat/completions"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "messages": [["role":"user", "content": system + "\n\n" + prompt]],
                    "stream": true, "max_tokens": 900, "temperature": 0.2, "top_p": 0.9,
                    "cache_prompt": false
                ])
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw OptionalModelError.message("本地Gemma拒绝了生成请求，请检查模型或缩小资料范围。")
                }
                var result = ""
                var done = false
                var outputBytes = 0
                for try await line in bytes.lines {
                    try checkGeneration(id)
                    outputBytes += line.utf8.count
                    guard outputBytes < 4 * 1024 * 1024 else { throw OptionalModelError.message("本地生成响应超出限制。") }
                    guard line.hasPrefix("data:") else { continue }
                    let dataText = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if dataText == "[DONE]" { done = true; break }
                    guard let data = dataText.data(using: .utf8), let envelope = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
                          let choices = envelope["choices"] as? [[String:Any]], let first = choices.first else { continue }
                    if let delta = first["delta"] as? [String:Any], let token = delta["content"] as? String, !token.isEmpty {
                        result += token; onToken(token)
                    }
                    if let finish = first["finish_reason"] as? String {
                        if finish == "length" { throw OptionalModelError.message("Gemma输出达到长度上限，未保存为完整结果。请缩小问题范围后重试。") }
                        done = finish == "stop"
                    }
                }
                try checkGeneration(id)
                guard done, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw OptionalModelError.message("本地模型没有完整返回结果，未覆盖已有笔记。")
                }
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                if Task.isCancelled || generation != id || cancelledGeneration == id { throw CancellationError() }
                throw error
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func cancel() {
        cancelledGeneration = generation
        stopServer()
    }
    func shutdown() { generation = nil; idleTask?.cancel(); idleTask = nil; stopServer() }
    private func releaseIfIdle() { if generation == nil { stopServer() } }
    private func checkGeneration(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id, cancelledGeneration != id else { throw CancellationError() }
    }

    private func resolveModel() async throws -> URL {
        guard let id = defaults.string(forKey: "optionalGemma.activeModel.v1"),
              let spec = OptionalModelSpec.all.first(where: { $0.id == id }) else {
            throw OptionalModelError.message("请先在设置 → 模型下载并启用Gemma。")
        }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(OptionalModelManifest.self, from: data)
        guard manifest.modelID == id, manifest.repository == spec.repository,
              let main = manifest.files.first(where: { $0.name.hasSuffix("Q4_K_M.gguf") }),
              main.name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw OptionalModelError.message("Gemma文件清单不匹配，无法启动。")
        }
        let model = directory.appendingPathComponent(main.name)
        if verifiedManifest == data && verifiedModel == model,
           let size = try model.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == main.bytes { return model }
        let valid = try await Task.detached(priority: .utility) { try OptionalModelIntegrity.verify(model, file: main) }.value
        guard valid else { throw OptionalModelError.message("Gemma权重校验失败，请重新下载。") }
        verifiedManifest = data; verifiedModel = model
        return model
    }
    private func ensureServer(model: URL, id: UUID) async throws {
        if let process, process.isRunning, modelPath == model { return }
        stopServer()
        let executable = executableOverride ?? Bundle.main.url(forResource: "llama-server", withExtension: nil, subdirectory: "Engine/Gemma")
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OptionalModelError.message("安装包缺少Gemma推理引擎，请安装完整版本。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoHear-Gemma-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        workDirectory = directory
        let key = UUID().uuidString + UUID().uuidString
        let keyFile = directory.appendingPathComponent("api-key")
        FileManager.default.createFile(atPath: keyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        let logFile = directory.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        log = try FileHandle(forWritingTo: logFile)
        let port = try Self.freePort()
        serverURL = URL(string: "http://127.0.0.1:\(port)")!
        apiKey = key
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--model",model.path,"--host","127.0.0.1","--port",String(port),
            "--ctx-size","8192","--parallel","1","--threads",String(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))),
            "--n-gpu-layers","99","--api-key-file",keyFile.path,"--no-webui"]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = log; child.standardError = log
        do { try child.run() } catch { stopServer(); throw error }
        process = child; modelPath = model
        GemmaProcessLifetime.shared.register(child)
        do {
            let expires = Date().addingTimeInterval(120)
            while Date() < expires {
                try checkGeneration(id)
                guard child.isRunning else { throw OptionalModelError.message("Gemma引擎未能启动，请检查模型或可用内存。") }
                var request = authorizedRequest(serverURL!.appendingPathComponent("health"))
                request.timeoutInterval = 2
                if let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { return }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw OptionalModelError.message("本地Gemma加载超时，建议选择4B模型并关闭占内存的应用后重试。")
        } catch { stopServer(); throw error }
    }
    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        return request
    }
    private func stopServer() {
        let child = process
        process = nil; serverURL = nil; modelPath = nil; apiKey = ""
        if let child, child.isRunning { child.terminate() }
        GemmaProcessLifetime.shared.register(nil)
        try? log?.close(); log = nil
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
    }
    private nonisolated static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw OptionalModelError.message("无法准备本地模型服务端口。") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw OptionalModelError.message("无法绑定本地模型服务端口。") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else { throw OptionalModelError.message("无法读取本地模型服务端口。") }
        return UInt16(bigEndian: address.sin_port)
    }
}
