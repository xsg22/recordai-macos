import AppKit
import Combine
import Foundation
import SwiftUI

/// Fixed personal Gmail workflow. All actual writes still require the user's explicit sync action.
@MainActor
final class GmailAccountConnection: ObservableObject {
    static let endpoint = "https://mcp.pipedream.net/v2"
    static let accountSetupURL = URL(string: "https://mcp.pipedream.com/app/gmail")!
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var status = "未连接 Gmail"
    @Published private(set) var accountDisplay = ""
    @Published var error: String?
    let store: MCPConnectionStore
    private let defaults: UserDefaults
    private let metadataKey: String
    private var email = ""
    @Published private(set) var canReopenAuthorization = false
    private var progressSubscription: AnyCancellable?
    private var connectionTask: Task<Void, Never>?

    init(store: MCPConnectionStore, defaults: UserDefaults = .standard, metadataNamespace: String = "gmail") {
        self.store = store; self.defaults = defaults
        store.configuration.endpoint = Self.endpoint
        metadataKey = "gmailAccountMetadata.v1." + metadataNamespace
        progressSubscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.canReopenAuthorization = self.store.authorizationURL != nil
                if self.busy { self.status = self.store.status }
            }
        }
        if let metadata = defaults.dictionary(forKey: metadataKey), let address = metadata["email"] as? String {
            accountDisplay = address
            status = "已保存 Gmail 账号，等待连接验证"
        }
    }

    /// User action: authorize the fixed third-party service and identify only the Gmail account.
    func connect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        connected = false; error = nil
        store.configuration.endpoint = Self.endpoint
        store.configuration.name = "个人 Gmail · Pipedream"
        store.configuration.scope = "openid profile email offline_access mcp"
        // 固定公开服务地址无需读写旧MCP地址钥匙串，避免在打开浏览器前被旧权限等待阻塞。
        status = "正在连接 Gmail…"
        store.error = nil
        if store.hasSavedAuthorization { await store.connect() }
        guard !Task.isCancelled else { status = "已取消连接"; return }
        if !store.connected {
            status = "正在准备 Gmail 授权页面…"
            store.error = nil
            await store.authorize()
            guard !Task.isCancelled else { store.error = nil; status = "已取消连接"; return }
            guard store.error == nil else { error = store.error; status = "Gmail 授权未完成"; return }
            store.error = nil
        await store.connect()
        }
        guard !Task.isCancelled else { status = "已取消连接"; return }
        await identifyAccount()
    }

    func startConnection() {
        guard !busy, connectionTask == nil else { return }
        connectionTask = Task { [weak self] in
            await self?.connect()
            self?.connectionTask = nil
        }
    }
    func cancelConnection() {
        connectionTask?.cancel()
        store.cancelAuthorization()
    }
    func reopenAuthorizationPage() { store.reopenAuthorizationPage(); error = store.error }

    /// App restart: read-only validation. Does not open OAuth, send email, or invoke any write tool.
    func restore() async {
        guard !busy, defaults.dictionary(forKey: metadataKey) != nil else { return }
        busy = true; defer { busy = false }
        connected = false
        guard store.configuration.endpoint == Self.endpoint else { status = "Gmail 服务配置已改变，请重新连接"; return }
        store.error = nil
        await store.connect()
        await identifyAccount()
    }

    private func identifyAccount() async {
        guard store.connected else { error = store.error; status = "Gmail 尚未连接"; return }
        do {
            let contract = try Self.contract(tools: store.tools)
            let result = try await store.readAccount(using: contract.profile)
            let account = try Self.account(from: result)
            email = account.email
            accountDisplay = account.name.isEmpty ? account.email : "\(account.name) · \(account.email)"
            store.configuration.tool = contract.send.name
            store.configuration.argumentTemplate = try Self.template(email: account.email)
            store.error = nil
            store.saveSyncAction()
            guard store.error == nil else { throw MCPError.message("Gmail 同步动作保存失败。") }
            defaults.set(["email": account.email, "name": account.name], forKey: metadataKey)
            connected = true; status = "已连接 · 会议将发给自己"
        } catch { connected = false; self.error = MCPConnectionStore.safeError(error); status = "Gmail 尚未就绪" }
    }

    /// Caller must pass final, completed transcript content after its user-visible confirmation.
    func sync(title: String, text: String) async throws -> MCPSyncReceipt {
        guard connected, !busy, !email.isEmpty, store.configuration.endpoint == Self.endpoint else {
            throw MCPError.message("请先连接并确认个人 Gmail 账号。")
        }
        busy = true; defer { busy = false }
        // Rebuild the fixed recipient mapping on every send, preventing an advanced-settings edit from changing recipients.
        let contract = try Self.contract(tools: store.tools)
        store.configuration.tool = contract.send.name
        store.configuration.argumentTemplate = try Self.template(email: email)
        return try await store.sync(title: title, text: text)
    }

    func disconnect() throws {
        try store.disconnect(); defaults.removeObject(forKey: metadataKey)
        connected = false; email = ""; accountDisplay = ""; status = "已断开 Gmail"
    }

    /// Pipedream's official component keys are fixed. Unknown wrappers / dynamic-discovery tools are not guessed.
    static func contract(tools: [MCPTool]) throws -> (profile: MCPTool, send: MCPTool) {
        guard let profile = tools.first(where: { $0.name == "gmail-get-current-user" }),
              profile.annotations?["readOnlyHint"] as? Bool == true,
              (profile.inputSchema["required"] as? [String] ?? []).isEmpty,
              let send = tools.first(where: { $0.name == "gmail-send-email" }),
              let properties = send.inputSchema["properties"] as? [String: [String: Any]],
              properties["to"]?["type"] as? String == "array",
              (properties["to"]?["items"] as? [String: Any])?["type"] as? String == "string",
              properties["subject"]?["type"] as? String == "string",
              properties["body"]?["type"] as? String == "string",
              Set(send.inputSchema["required"] as? [String] ?? []).isSubset(of: ["to", "subject", "body", "bodyType"]) else {
            throw MCPError.message("Pipedream 尚未返回可验证的 Gmail 个人账号与发信工具。请在 Pipedream 启用 Gmail 后重新连接；当前服务工具契约不兼容时不会发送会议。")
        }
        return (profile, send)
    }

    static func account(from result: [String: Any]) throws -> (email: String, name: String) {
        var value = result["structuredContent"] as? [String: Any]
        if value == nil, let contents = result["content"] as? [[String: Any]] {
            for item in contents {
                guard let text = item["text"] as? String, let data = text.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                value = json; break
            }
        }
        guard let value, let email = value["emailAddress"] as? String,
              email.range(of: #"^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$"#, options: .regularExpression) != nil else {
            throw MCPError.message("Gmail 账号工具未返回可验证的 emailAddress，不会推测收件人。")
        }
        return (email, value["name"] as? String ?? "")
    }

    static func template(email: String) throws -> String {
        let value: [String: Any] = ["to": [email], "subject": "{{title}}", "body": "{{text}}", "bodyType": "plaintext"]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
