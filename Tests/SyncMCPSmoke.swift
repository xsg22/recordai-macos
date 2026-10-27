import Foundation
final class MCPStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct SyncMCPSmoke {
    static func check(_ value: Bool, _ message: String) throws { if !value { throw MCPError.message("FAIL: " + message) } }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
        let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MCPStubProtocol.self]
        let session = URLSession(configuration: configuration)
        var calls = 0
        MCPStubProtocol.handler = { request in
            calls += 1
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "Bearer header")
            let payload = try body(request), method = payload["method"] as! String
            if method == "notifications/initialized" { return (202, [:], Data()) }
            var result: [String: Any]
            switch method {
            case "initialize": result = ["protocolVersion": "2025-06-18"]
            case "tools/list":
                try check(request.value(forHTTPHeaderField: "Mcp-Session-Id") == "session-1", "session header")
                result = ["tools": [["name": "save", "inputSchema": ["type": "object"]]]]
            default:
                let args = (payload["params"] as! [String: Any])["arguments"] as! [String: Any]
                try check(args["title"] as? String == "中文\"标题", "quote replacement")
                try check(args["text"] as? String == "第一行\n第二行", "newline replacement")
                result = ["content": [["type": "text", "text": "已保存"]], "structuredContent": ["url": "https://example.com/document/1"]]
            }
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": payload["id"]!, "result": result])
            return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "session-1"], data)
        }
        let endpoint = URL(string: "https://mcp.example.com/mcp")!
        let client = MCPClient(endpoint: endpoint, token: "test-token", session: session)
        let tools = try await client.tools(); try check(tools.count == 1, "tools")
        let receipt = try await client.sync(title: "中文\"标题", text: "第一行\n第二行", tool: "save", argumentTemplate: "{\"title\":\"{{title}}\",\"text\":\"{{text}}\"}")
        try check(receipt.remoteURL?.host == "example.com" && calls == 4, "receipt and RPC sequence")
        MCPStubProtocol.handler = { request in
            let payload = try body(request)
            if payload["method"] as? String == "notifications/initialized" { return (202, [:], Data()) }
            let result: [String: Any] = payload["method"] as? String == "initialize" ? ["protocolVersion": "2025-06-18"] : ["isError": true, "content": [["text": "secret-token"]]]
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": payload["id"]!, "result": result])
            return (200, ["Content-Type": "text/event-stream"], Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8))
        }
        var rejected = false
        do { _ = try await MCPClient(endpoint: endpoint, session: session).sync(title: "a", text: "b", tool: "save", argumentTemplate: "{}") }
        catch { rejected = true; try check(!error.localizedDescription.contains("secret-token"), "sanitized tool error") }
        try check(rejected, "tool error rejected")
        MCPStubProtocol.handler = { _ in (401, [:], Data("secret-token".utf8)) }
        rejected = false
        do { _ = try await MCPClient(endpoint: endpoint, session: session).tools() }
        catch { rejected = true; try check(error.localizedDescription.contains("未授权"), "401") }
        try check(rejected, "401 rejected")
        let literalContent = try MCPClient.arguments(template: "{\"title\":\"{{title}}\",\"text\":\"{{text}}\"}", title: "标题包含{{text}}", text: "正文包含{{title}}")
        try check(literalContent["title"] as? String == "标题包含{{text}}" && literalContent["text"] as? String == "正文包含{{title}}", "user content placeholders are not evaluated again")
        let stored = String(decoding: try JSONEncoder().encode(MCPConnectionConfiguration()), as: UTF8.self)
        try check(!stored.contains("endpoint"), "endpoint omitted from preferences")
        var refreshRequests = 0
        var expectedCanonicalResource = endpoint.absoluteString
        MCPStubProtocol.handler = { request in
            refreshRequests += 1
            try check(request.url?.absoluteString == "https://auth.example.com/token", "same refresh endpoint")
            let encoded = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            // URLSession may convert an HTTP body into a stream before reaching URLProtocol.
            var formData = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; formData.append(contentsOf: buffer.prefix(count)) }
            }
            let form = String(decoding: formData, as: UTF8.self)
            try check(form.contains("grant_type=refresh_token") && !form.contains("scope="), "refresh grant without new scope")
            let formFields = URLComponents(string: "https://form.invalid/?" + form)?.queryItems
            try check(formFields?.first(where: { $0.name == "resource" })?.value == expectedCanonicalResource, "refresh sends saved canonical resource")
            try check(!form.isEmpty || !encoded.isEmpty, "refresh request body")
            return (200, ["Content-Type": "application/json"], Data("{\"access_token\":\"renewed\",\"refresh_token\":\"rotated\",\"expires_in\":3600,\"token_type\":\"Bearer\"}".utf8))
        }
        let expired = MCPCredential(accessToken: "expired", expiresAt: Date(timeIntervalSince1970: 0), refreshToken: "refresh-old", clientID: "public-client", tokenEndpoint: "https://auth.example.com/token", resource: endpoint.absoluteString)
        let renewed = try await MCPConnectionStore.refreshCredential(expired, resource: endpoint.absoluteString, session: session)
        try check(renewed.accessToken == "renewed" && renewed.refreshToken == "rotated" && renewed.expiresAt! > Date(), "rotating refresh credential")
        rejected = false
        do { _ = try await MCPConnectionStore.refreshCredential(expired, resource: "https://other.example.com/mcp", session: session) }
        catch { rejected = true }
        try check(rejected && refreshRequests == 1, "wrong resource rejected before network")
        let pipedreamEndpoint = URL(string: "https://mcp.pipedream.net/v2")!
        let canonical = try MCPConnectionStore.validatedOAuthResource("https://mcp.pipedream.net", endpoint: pipedreamEndpoint)
        try check(canonical.absoluteString == "https://mcp.pipedream.net", "metadata origin resource distinct from endpoint path")
        let pipedreamCredential = MCPCredential(accessToken: "expired", expiresAt: Date(timeIntervalSince1970: 0), refreshToken: "refresh-old", clientID: "public-client", tokenEndpoint: "https://auth.example.com/token", resource: canonical.absoluteString)
        expectedCanonicalResource = canonical.absoluteString
        let refreshedCanonical = try await MCPConnectionStore.refreshCredential(pipedreamCredential, resource: pipedreamEndpoint.absoluteString, session: session)
        try check(refreshedCanonical.resource == canonical.absoluteString && refreshRequests == 2, "origin resource refresh with /v2 endpoint")
        rejected = false
        do { _ = try MCPConnectionStore.validatedOAuthResource("https://mcp.pipedream.net:444", endpoint: pipedreamEndpoint) }
        catch { rejected = true }
        try check(rejected, "different resource port rejected")
        rejected = false
        do { _ = try MCPConnectionStore.validatedOAuthResource("http://mcp.pipedream.net", endpoint: pipedreamEndpoint) }
        catch { rejected = true }
        try check(rejected, "non-HTTPS resource rejected")
        let legacy = try JSONDecoder().decode(MCPCredential.self, from: Data("{\"accessToken\":\"old\"}".utf8))
        try check(legacy.refreshToken == nil, "legacy Keychain migration")
        print("PASS: discovery/session/JSON/SSE/tool error/HTTP401/endpoint privacy/refresh rotation/resource binding/canonical OAuth resource/legacy credentials")
    }
}
