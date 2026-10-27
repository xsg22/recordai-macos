import Foundation

enum AccountCommandFailure: Error { case notConfigured }

/// 内置官方CLI仅通过结构化参数执行；不启动shell、不输出凭证或完整服务地址。
actor AccountCommandRunner {
    static func run(executable: URL, arguments: [String], input: Data? = nil, directory: URL? = nil, timeout: TimeInterval = 300) async throws -> [String: Any] {
        try await Task.detached(priority: .userInitiated) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoHear-account-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let stdoutURL = root.appendingPathComponent("output"), stderrURL = root.appendingPathComponent("error")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let stdout = try FileHandle(forWritingTo: stdoutURL), stderr = try FileHandle(forWritingTo: stderrURL)
            defer { try? stdout.close(); try? stderr.close() }
            let process = Process()
            process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
            process.standardOutput = stdout; process.standardError = stderr
            let inputURL = root.appendingPathComponent("input")
            try (input ?? Data()).write(to: inputURL, options: .atomic)
            let stdin = try FileHandle(forReadingFrom: inputURL)
            defer { try? stdin.close() }
            process.standardInput = stdin
            try process.run()
            // 浏览器授权允许用户完成；超时只终止本次辅助进程，不清理其他客户端授权。
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            process.waitUntilExit(); deadline.cancel()
            guard process.terminationStatus == 0 else {
                for url in [stdoutURL, stderrURL] {
                    if let data = try? Data(contentsOf: url),
                       let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = result["error"] as? [String: Any],
                       error["type"] as? String == "config", error["subtype"] as? String == "not_configured" {
                        throw AccountCommandFailure.notConfigured
                    }
                }
                throw MCPError.message("账号服务操作未完成（\(process.terminationStatus)）。请检查登录授权与文档权限后重试；不会自动重复发送。")
            }
            let data = try Data(contentsOf: stdoutURL)
            guard data.count < 16 * 1024 * 1024 else { throw MCPError.message("账号服务响应过大。") }
            return try parse(data)
        }.value
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return try validated(result) }
        // 登录CLI可能先打印浏览器进度，仅接受后面的完整JSON对象。
        let text = String(decoding: data, as: UTF8.self)
        for index in text.indices where text[index] == "{" {
            if let result = try? JSONSerialization.jsonObject(with: Data(text[index...].utf8)) as? [String: Any] { return try validated(result) }
        }
        throw MCPError.message("账号服务没有返回有效结果。")
    }
    private static func validated(_ result: [String: Any]) throws -> [String: Any] {
        guard result["ok"] as? Bool != false, result["success"] as? Bool != false, result["error"] == nil,
              result["status"] as? String != "failed" else { throw MCPError.message("账号服务返回失败，请检查登录与权限。") }
        return result
    }
}
