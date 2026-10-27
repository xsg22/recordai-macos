import Foundation

struct MCPTool: Identifiable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    var annotations: [String: Any]? = nil
    var id: String { name }
}

struct MCPSyncReceipt {
    let tool: String
    let result: String
    let remoteURL: URL?
    var warning: String? = nil
    var notificationStatus: String? = nil
    var structuredContent: [String: Any]? = nil
}

enum MCPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

/// Streamable HTTP only. The service URL is provided by the user, never inferred from a platform name.
actor MCPClient {
    let endpoint: URL
    private let token: String?
    private let session: URLSession
    private var sessionID: String?
    private var requestID = 0
    private var initialized = false
    private var protocolVersion = "2025-06-18"
    init(endpoint: URL, token: String? = nil, session: URLSession = .shared) {
        self.endpoint = endpoint; self.token = token; self.session = session
    }

    func initialize() async throws {
        guard !initialized else { return }
        let result = try await request(method: "initialize", params: [
            "protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "CoHearTranscribe", "version": "0.6.0"]
        ])
        guard let version = result["protocolVersion"] as? String,
              ["2025-06-18", "2025-03-26"].contains(version) else {
            throw MCPError.message("MCP 服务返回了不支持的协议版本。")
        }
        protocolVersion = version
        try await notification(method: "notifications/initialized")
        initialized = true
    }

    func tools() async throws -> [MCPTool] {
        try await initialize()
        var all: [MCPTool] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let result = try await request(method: "tools/list", params: cursor.map { ["cursor": $0] } ?? [:])
            guard let tools = result["tools"] as? [[String: Any]] else { throw MCPError.message("MCP 工具列表格式无效。") }
            all += tools.compactMap { item in
                guard let name = item["name"] as? String, let schema = item["inputSchema"] as? [String: Any] else { return nil }
                return MCPTool(name: name, description: item["description"] as? String ?? "", inputSchema: schema, annotations: item["annotations"] as? [String: Any])
            }
            cursor = result["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw MCPError.message("MCP 工具分页游标重复。") }
            if all.count > 2000 { throw MCPError.message("MCP 工具数量超过客户端限制。") }
        } while cursor != nil
        return all
    }

    func callReadOnly(tool: MCPTool, arguments: [String: Any]) async throws -> [String: Any] {
        guard tool.annotations?["readOnlyHint"] as? Bool == true else { throw MCPError.message("账号识别工具没有声明只读，已停止自动调用。") }
        try await initialize()
        let result = try await request(method: "tools/call", params: ["name": tool.name, "arguments": arguments])
        guard result["isError"] as? Bool != true else { throw MCPError.message("账号识别失败，请检查该服务的个人账号授权后重新连接。") }
        return result
    }

    /// The user selects the tool and reviews its argument template before this function is called.
    /// The application must pass a completed final-transcript snapshot, never live preview text.
    func sync(title: String, text: String, tool: String, argumentTemplate: String) async throws -> MCPSyncReceipt {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPError.message("没有可以同步的会议文本。") }
        let arguments = try Self.arguments(template: argumentTemplate, title: title, text: text)
        try await initialize()
        let result = try await request(method: "tools/call", params: ["name": tool, "arguments": arguments])
        guard result["isError"] as? Bool != true else {
            // Do not display an untrusted response that could contain an echoed token.
            throw MCPError.message("远端工具报告执行失败，请在服务端检查权限和参数。")
        }
        let contents = result["content"] as? [[String: Any]] ?? []
        let message = contents.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let structured = result["structuredContent"] as? [String: Any]
        let candidate = (structured?["url"] as? String) ?? (structured?["webUrl"] as? String)
        let url = candidate.flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
        return MCPSyncReceipt(tool: tool, result: message.isEmpty ? "工具执行完成；请到目标平台核对结果。" : message, remoteURL: url, structuredContent: structured)
    }

    static func arguments(template: String, title: String, text: String) throws -> [String: Any] {
        guard let data = template.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.message("参数模板必须是 JSON 对象。")
        }
        func replace(_ value: Any) -> Any {
            if let string = value as? String {
                // Replace only placeholders from the template, never placeholders contained in user content.
                let pattern = try! NSRegularExpression(pattern: #"\{\{(title|text)\}\}"#)
                let matches = pattern.matches(in: string, range: NSRange(string.startIndex..., in: string))
                var rendered = string
                for match in matches.reversed() {
                    guard let range = Range(match.range, in: rendered), let nameRange = Range(match.range(at: 1), in: string) else { continue }
                    rendered.replaceSubrange(range, with: string[nameRange] == "title" ? title : text)
                }
                return rendered
            }
            if let array = value as? [Any] { return array.map(replace) }
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(replace) }
            return value
        }
        return object.mapValues(replace)
    }

    private func notification(method: String) async throws {
        _ = try await send(["jsonrpc": "2.0", "method": method], expectsResponse: false)
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        requestID += 1
        let id = requestID
        guard let envelope = try await send(["jsonrpc": "2.0", "id": id, "method": method, "params": params], expectsResponse: true, expectedID: id) else {
            throw MCPError.message("MCP 没有返回结果。")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw MCPError.message("MCP 请求失败（错误码 \(error["code"] ?? "未知")），请检查服务权限和参数。")
        }
        guard let result = envelope["result"] as? [String: Any] else { throw MCPError.message("MCP 返回结果格式无效。") }
        return result
    }

    private func send(_ payload: [String: Any], expectsResponse: Bool, expectedID: Int? = nil) async throws -> [String: Any]? {
        guard endpoint.scheme == "https" || (endpoint.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(endpoint.host ?? "")) else {
            throw MCPError.message("远程 MCP 必须使用 HTTPS；只有本机服务允许 HTTP。")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MCPError.message("MCP 网络请求失败，请检查网络或服务地址。") }
        guard let http = response as? HTTPURLResponse else { throw MCPError.message("MCP 网络响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw MCPError.message("连接未授权或授权已过期，请重新连接授权。") }
            throw MCPError.message("MCP HTTP \(http.statusCode)，请检查地址、权限或服务状态。")
        }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        guard expectsResponse else { return nil }
        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            var fragments: [String] = []
            var totalBytes = 0
            for try await line in bytes.lines {
                totalBytes += line.utf8.count
                guard totalBytes <= 8 * 1024 * 1024 else { throw MCPError.message("MCP 响应超过大小限制。") }
                if line.hasPrefix("data:") { fragments.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
                if line.isEmpty && !fragments.isEmpty {
                    let body = Data(fragments.joined(separator: "\n").utf8)
                    fragments = []
                    if let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any], value["id"] as? Int == expectedID { return value }
                }
            }
            if !fragments.isEmpty {
                let body = Data(fragments.joined(separator: "\n").utf8)
                if let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any], value["id"] as? Int == expectedID { return value }
            }
            throw MCPError.message("MCP 事件流中没有匹配的结果。")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= 8 * 1024 * 1024 else { throw MCPError.message("MCP 响应超过大小限制。") }
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["id"] as? Int == expectedID else {
            throw MCPError.message("MCP 响应 ID 不匹配。")
        }
        return value
    }
}
