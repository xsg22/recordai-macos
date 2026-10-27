import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import SwiftUI

struct MCPConnectionConfiguration: Codable {
    var name = "个人工作区"
    var endpoint = ""
    var scope = ""
    var tool = ""
    enum CodingKeys: String, CodingKey { case name, scope, tool, argumentTemplate }
    var argumentTemplate = "{\n  \"title\": \"{{title}}\",\n  \"text\": \"{{text}}\"\n}"
}

struct MCPCredential: Codable {
    let accessToken: String
    let expiresAt: Date?
    var refreshToken: String? = nil
    var clientID: String? = nil
    var tokenEndpoint: String? = nil
    var resource: String? = nil
}

/// A refresh token must never follow a redirect to another endpoint.
private final class MCPOAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// OAuth credentials never enter preferences, transcript files, logs, or subprocess arguments.
enum MCPKeychain {
    static let service = "com.cohear.transcribe.personal-mcp"
    static func read(account: String) throws -> MCPCredential? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MCPError.message("读取钥匙串授权失败（\(status)）。") }
        return try JSONDecoder().decode(MCPCredential.self, from: data)
    }
    static func save(_ credential: MCPCredential, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credential),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let inserted = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw MCPError.message("保存钥匙串授权失败（\(inserted)）。") }
        } else if status != errSecSuccess { throw MCPError.message("更新钥匙串授权失败（\(status)）。") }
    }
    static func delete(account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MCPError.message("移除钥匙串授权失败（\(status)）。") }
    }
}

@MainActor
final class MCPConnectionStore: NSObject, ObservableObject {
    @Published var configuration: MCPConnectionConfiguration
    @Published var tools: [MCPTool] = []
    @Published var status = "未连接"
    @Published var busy = false
    @Published var error: String?
    @Published private(set) var connected = false
    private var client: MCPClient?
    @Published private(set) var authorizationURL: URL?
    private let browserFlow = BrowserAuthorizationCoordinator()
    private let defaults: UserDefaults
    private let namespace: String
    private var connectedEndpoint: String?
    private static let preferenceKey = "personalMCPConfiguration.v1"
    static let redirectURI = "coheartranscribe://oauth/callback"

    init(defaults: UserDefaults = .standard, namespace: String = "default") {
        self.defaults = defaults
        self.namespace = namespace
        if let data = defaults.data(forKey: Self.preferenceKey + "." + namespace), let value = try? JSONDecoder().decode(MCPConnectionConfiguration.self, from: data) {
            configuration = value
        } else { configuration = MCPConnectionConfiguration() }
        super.init()
        browserFlow.onURLChanged = { [weak self] url in
            self?.authorizationURL = url
            if url != nil { self?.status = "已打开默认浏览器，请完成账号授权" }
        }
        // 不在主线程启动构造期读钥匙串；测试签名更新可能触发系统权限等待，导致无窗口。
        configuration.endpoint = ""
    }

    var personalActions: [PersonalSyncAction] { PersonalSyncAction.discover(tools) }
    var capabilityExplanation: String {
        if tools.contains(where: { ["batch_send_robot_msg_to_users", "create_robot", "send_message_by_custom_robot"].contains($0.name) }) {
            return "当前连接的是机器人消息服务，发送还需要指定机器人和接收人，它不能直接保存到你的个人文档。请连接支持个人文档的服务；软件不会替你选择批量发送或群广播。"
        }
        return "当前服务的个人保存接口尚未适配。连接成功不代表已能保存会议；无需猜工具或填写 JSON。接入适配完成后，这里会显示保存方式。"
    }
    var selectedTool: MCPTool? { tools.first { $0.name == configuration.tool } }
    var targetDescription: String { "\(configuration.name) · \(URL(string: configuration.endpoint)?.host ?? "未设置地址") · \(configuration.tool.isEmpty ? "保存位置尚未设置" : "已设置保存方式")" }

    func saveConfiguration() {
        do {
            let endpoint = try endpointURL()
            if let previous = try MCPKeychain.read(account: "configured-endpoint-" + namespace),
               previous.accessToken != endpoint.absoluteString, let oldURL = URL(string: previous.accessToken) {
                try MCPKeychain.delete(account: credentialAccount(oldURL))
            }
            try MCPKeychain.save(MCPCredential(accessToken: endpoint.absoluteString, expiresAt: nil), account: "configured-endpoint-" + namespace)
            defaults.set(try JSONEncoder().encode(configuration), forKey: Self.preferenceKey + "." + namespace)
        } catch { self.error = Self.safeError(error); return }
        // A changed destination invalidates the visible connection. Connect always validates the current endpoint.
        if connectedEndpoint != configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) {
            connected = false; client = nil; tools = []; status = "配置已保存，请连接验证"
        } else { status = "配置已保存 · 已连接" }
    }

    func connect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        connected = false; client = nil; tools = []
        do {
            if configuration.endpoint.isEmpty {
                configuration.endpoint = (try MCPKeychain.read(account: "configured-endpoint-" + namespace))?.accessToken ?? ""
            }
            let endpoint = try endpointURL()
            var credential = try MCPKeychain.read(account: credentialAccount(endpoint))
            if let current = credential, let expiry = current.expiresAt, expiry <= Date() {
                status = "正在刷新授权…"
                let refreshed = try await Self.refreshCredential(current, resource: endpoint.absoluteString)
                try MCPKeychain.save(refreshed, account: credentialAccount(endpoint))
                credential = refreshed
            }
            let candidate = MCPClient(endpoint: endpoint, token: credential?.accessToken)
            tools = try await candidate.tools()
            client = candidate; connected = true; connectedEndpoint = endpoint.absoluteString; status = "已连接 · \(tools.count) 个工具"
        } catch { self.error = Self.safeError(error); status = "未连接" }
    }

    /// Runs OAuth discovery and public-client dynamic registration, with PKCE and state validation.
    func authorize() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        connected = false; client = nil; tools = []
        do {
            let endpoint = try endpointURL()
            guard endpoint.query == nil else { throw MCPError.message("该地址包含服务提供的授权参数，请直接连接验证；不将地址中的凭证交给其他授权服务。") }
            status = "发现 MCP 授权服务…"
            var resourceDiscovery = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            resourceDiscovery.path = "/.well-known/oauth-protected-resource" + (endpoint.path == "/" ? "" : endpoint.path)
            resourceDiscovery.query = nil; resourceDiscovery.fragment = nil
            let resource: [String: Any]
            do { resource = try await getJSON(resourceDiscovery.url!) }
            catch {
                resourceDiscovery.path = "/.well-known/oauth-protected-resource"
                resource = try await getJSON(resourceDiscovery.url!)
            }
            guard let resourceValue = resource["resource"] as? String else { throw MCPError.message("MCP 授权元数据缺少 resource 标识。") }
            let canonicalResource = try Self.validatedOAuthResource(resourceValue, endpoint: endpoint)
            guard let servers = resource["authorization_servers"] as? [String], let server = servers.first,
                  let issuer = URL(string: server), issuer.scheme == "https" else {
                throw MCPError.message("该 MCP 未提供标准 OAuth 授权服务。请使用服务方提供的连接方式，或高级 Bearer 授权。")
            }
            var metadataURL = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
            metadataURL.path = "/.well-known/oauth-authorization-server" + (issuer.path == "/" ? "" : issuer.path)
            status = "正在读取授权服务信息…"
            let metadata = try await getJSON(metadataURL.url!)
            guard let metadataIssuer = metadata["issuer"] as? String, metadataIssuer == server else { throw MCPError.message("OAuth 服务元数据 issuer 不匹配。") }
            guard let registration = metadata["registration_endpoint"] as? String,
                  let authorization = metadata["authorization_endpoint"] as? String,
                  let tokenEndpoint = metadata["token_endpoint"] as? String,
                  (metadata["code_challenge_methods_supported"] as? [String])?.contains("S256") == true else {
                throw MCPError.message("该 MCP 不支持免应用配置的动态注册与 PKCE。需要服务方提供可用客户端连接入口；本软件不会代注册开放平台应用。")
            }
            status = "正在获取浏览器授权地址…"
            let registered = try await postJSON(try secureURL(registration), body: [
                "client_name": "倾听转录", "redirect_uris": [Self.redirectURI],
                "grant_types": (metadata["grant_types_supported"] as? [String])?.contains("refresh_token") == true ? ["authorization_code", "refresh_token"] : ["authorization_code"], "response_types": ["code"], "token_endpoint_auth_method": "none"
            ])
            guard let clientID = registered["client_id"] as? String,
                  (registered["token_endpoint_auth_method"] as? String ?? "none") == "none" else {
                throw MCPError.message("OAuth 服务没有接受公共客户端注册，无法安全完成免密钥授权。")
            }
            let verifier = try randomString()
            let state = try randomString()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
            var authURL = URLComponents(url: try secureURL(authorization), resolvingAgainstBaseURL: false)!
            var items = authURL.queryItems ?? []
            items += [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
                      URLQueryItem(name: "redirect_uri", value: Self.redirectURI), URLQueryItem(name: "state", value: state),
                      URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
                      URLQueryItem(name: "resource", value: canonicalResource.absoluteString)]
            if !configuration.scope.isEmpty { items.append(URLQueryItem(name: "scope", value: configuration.scope)) }
            authURL.queryItems = items
            let callback = try await browserAuthorize(authURL.url!)
            let callbackItems = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard callback.scheme == "coheartranscribe", callback.host == "oauth", callback.path == "/callback",
                  callbackItems.first(where: { $0.name == "state" })?.value == state else { throw MCPError.message("OAuth 回调校验失败。") }
            guard let code = callbackItems.first(where: { $0.name == "code" })?.value else { throw MCPError.message("授权被取消或服务未返回授权码。") }
            var tokenRequest = URLRequest(url: try secureURL(tokenEndpoint))
            tokenRequest.httpMethod = "POST"; tokenRequest.timeoutInterval = 30
            tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [URLQueryItem(name: "grant_type", value: "authorization_code"), URLQueryItem(name: "code", value: code),
                               URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
                               URLQueryItem(name: "code_verifier", value: verifier), URLQueryItem(name: "resource", value: canonicalResource.absoluteString)]
            tokenRequest.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            let token = try await fetchJSON(tokenRequest)
            guard let accessToken = token["access_token"] as? String,
                  (token["token_type"] as? String)?.lowercased() == "bearer" else { throw MCPError.message("OAuth 未返回有效 Bearer 授权。") }
            let expiry = (token["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
            let credential = MCPCredential(accessToken: accessToken, expiresAt: expiry,
                                           refreshToken: token["refresh_token"] as? String, clientID: clientID,
                                           tokenEndpoint: try secureURL(tokenEndpoint).absoluteString, resource: canonicalResource.absoluteString)
            try MCPKeychain.save(credential, account: credentialAccount(endpoint))
            status = "已授权，请连接验证"
        } catch { self.error = Self.safeError(error); status = "未授权" }
    }

    func saveBearer(_ token: String) throws {
        let endpoint = try endpointURL()
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPError.message("授权令牌不能为空。") }
        try MCPKeychain.save(MCPCredential(accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines), expiresAt: nil), account: credentialAccount(endpoint))
        connected = false; client = nil; tools = []; status = "授权已保存，请连接验证"
    }

    func disconnect() throws {
        try MCPKeychain.delete(account: credentialAccount(try endpointURL()))
        try MCPKeychain.delete(account: "configured-endpoint-" + namespace)
        configuration.endpoint = ""
        connectedEndpoint = nil
        connected = false; client = nil; tools = []; status = "已移除本机授权和服务地址"
    }

    func readAccount(using tool: MCPTool) async throws -> [String: Any] {
        guard connected, connectedEndpoint == configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines), let client,
              tools.contains(where: { $0.name == tool.name }) else { throw MCPError.message("请先连接 MCP 服务。") }
        return try await client.callReadOnly(tool: tool, arguments: [:])
    }

    /// Callers must gate on a completed meeting and pass a stable final-transcript snapshot.
    func sync(title: String, text: String) async throws -> MCPSyncReceipt {
        guard !busy, connected, connectedEndpoint == configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines), let client, selectedTool != nil else { throw MCPError.message("请先连接 MCP，并明确选择用于保存会议的工具。") }
        guard configuration.argumentTemplate.contains("{{text}}") else { throw MCPError.message("参数模板必须包含 {{text}}，以明确同步会议正文。") }
        let arguments = try MCPClient.arguments(template: configuration.argumentTemplate, title: title, text: text)
        if let required = selectedTool?.inputSchema["required"] as? [String], required.contains(where: { arguments[$0] == nil }) {
            throw MCPError.message("参数模板缺少工具必填字段，请核对 JSON Schema。")
        }
        busy = true; defer { busy = false }
        return try await client.sync(title: title, text: text, tool: configuration.tool, argumentTemplate: configuration.argumentTemplate)
    }

    /// Refresh only against the original validated HTTPS token endpoint and original MCP resource.
    /// No scope parameter is sent, so refresh cannot request expanded permissions.
    static func refreshCredential(_ credential: MCPCredential, resource: String, session injectedSession: URLSession? = nil) async throws -> MCPCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty,
              let clientID = credential.clientID, !clientID.isEmpty,
              let savedResource = credential.resource, let mcpEndpoint = URL(string: resource),
              let value = credential.tokenEndpoint, let url = URL(string: value),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.fragment == nil else { throw MCPError.message("授权已过期且无法自动刷新，请重新授权。") }
        let canonicalResource = try validatedOAuthResource(savedResource, endpoint: mcpEndpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"),
                           URLQueryItem(name: "refresh_token", value: refreshToken),
                           URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "resource", value: canonicalResource.absoluteString)]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let session = injectedSession ?? URLSession(configuration: .ephemeral, delegate: MCPOAuthNoRedirectDelegate(), delegateQueue: nil)
        defer { if injectedSession == nil { session.finishTasksAndInvalidate() } }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw MCPError.message("刷新授权网络请求失败，请检查网络后重新连接。") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url == url, let token = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              token["error"] == nil, let accessToken = token["access_token"] as? String, !accessToken.isEmpty,
              (token["token_type"] as? String)?.lowercased() == "bearer" else {
            throw MCPError.message("刷新授权失败，原授权可能已撤销，请重新授权。")
        }
        if let expiry = token["expires_in"] as? Double, expiry <= 0 { throw MCPError.message("刷新授权返回了无效过期时间，请重新授权。") }
        return MCPCredential(accessToken: accessToken,
                             expiresAt: (token["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
                             refreshToken: (token["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken,
                             clientID: clientID, tokenEndpoint: value, resource: savedResource)
    }

    /// The protected-resource metadata identifies the OAuth resource, which may be the server origin rather than /v2.
    /// Only HTTPS resources with the same origin as the configured MCP endpoint are accepted.
    static func validatedOAuthResource(_ value: String, endpoint: URL) throws -> URL {
        guard let resource = URL(string: value), resource.scheme == "https", endpoint.scheme == "https",
              resource.user == nil, resource.password == nil, resource.query == nil, resource.fragment == nil,
              let host = resource.host, host.lowercased() == endpoint.host?.lowercased(),
              (resource.port ?? 443) == (endpoint.port ?? 443) else {
            throw MCPError.message("OAuth resource 必须是与 MCP 服务同源的 HTTPS 地址。")
        }
        return resource
    }

    func saveSyncAction() {
        guard selectedTool != nil else { error = "请先连接并选择一个同步工具。"; return }
        do {
            guard configuration.argumentTemplate.contains("{{text}}") else { throw MCPError.message("参数模板必须包含 {{text}}。") }
            _ = try MCPClient.arguments(template: configuration.argumentTemplate, title: "预览标题", text: "预览正文")
            saveConfiguration()
        } catch { self.error = Self.safeError(error) }
    }

    var hasSavedAuthorization: Bool {
        guard let endpoint = try? endpointURL() else { return false }
        return (try? MCPKeychain.read(account: credentialAccount(endpoint))) != nil
    }
    func reopenAuthorizationPage() {
        if !browserFlow.reopen() { error = "授权地址尚未就绪或无法打开浏览器，请检查当前连接步骤。" }
    }
    func cancelAuthorization() { browserFlow.cancel() }
    private func browserAuthorize(_ url: URL) async throws -> URL {
        try await browserFlow.authorize(url)
    }
    static func safeError(_ error: Error) -> String {
        if let network = error as? URLError, network.code == .timedOut {
            return "授权服务连接超时，请检查网络后重试。尚未取得授权地址时不会显示浏览器已打开。"
        }
        if error is CancellationError { return "已取消授权等待。" }
        return (error as? MCPError)?.localizedDescription ?? "连接请求失败，请检查网络与服务配置。"
    }
    private func credentialAccount(_ endpoint: URL) -> String {
        "token-" + namespace + "-" + SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func endpointURL() throws -> URL {
        guard let url = URL(string: configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")) else {
            throw MCPError.message("请输入服务提供的有效 MCP HTTPS 地址；本机可用 HTTP。")
        }
        return url
    }
    private func secureURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw MCPError.message("OAuth 服务地址必须使用 HTTPS。") }
        return url
    }
    private func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPError.message("无法生成安全授权随机数。") }
        return Data(bytes).base64URLEncoded()
    }
    private func getJSON(_ url: URL) async throws -> [String: Any] { try await fetchJSON(URLRequest(url: url)) }
    private func postJSON(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await fetchJSON(request)
    }
    private func fetchJSON(_ original: URLRequest) async throws -> [String: Any] {
        var request = original
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.message("授权服务响应无效。") }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.message("授权服务请求失败（HTTP \(http.statusCode)），浏览器授权尚未开始。")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil else { throw MCPError.message("OAuth 服务拒绝请求，请检查权限或服务配置。") }
        return json
    }
}

private extension Data {
    func base64URLEncoded() -> String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
