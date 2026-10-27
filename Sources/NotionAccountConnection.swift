import Combine
import Foundation
import SwiftUI

@MainActor
final class NotionAccountConnection: ObservableObject {
    static let endpoint = "https://mcp.notion.com/mcp"
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var status = "未连接 Notion"
    @Published private(set) var accountDisplay = ""
    @Published private(set) var canReopenAuthorization = false
    @Published var error: String?
    let store: MCPConnectionStore
    private let defaults: UserDefaults
    private let metadataKey: String
    private var workspaceID = ""
    private var progress: AnyCancellable?
    private var connectionTask: Task<Void, Never>?

    init(store: MCPConnectionStore, defaults: UserDefaults = .standard, metadataNamespace: String = "notion") {
        self.store = store; self.defaults = defaults
        metadataKey = "notionAccount.v1." + metadataNamespace
        store.configuration.endpoint = Self.endpoint
        store.configuration.name = "个人 Notion"
        store.configuration.scope = "default"
        if let metadata = defaults.dictionary(forKey: metadataKey) {
            workspaceID = metadata["workspaceID"] as? String ?? ""
            accountDisplay = metadata["display"] as? String ?? ""
            status = "已保存工作区，等待验证连接"
        }
        progress = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.canReopenAuthorization = self.store.authorizationURL != nil
                if self.busy { self.status = self.store.status }
            }
        }
    }
    func startConnection() {
        guard !busy, connectionTask == nil else { return }
        connectionTask = Task { [weak self] in
            await self?.connect()
            self?.connectionTask = nil
        }
    }
    func cancelConnection() { connectionTask?.cancel(); store.cancelAuthorization() }
    func reopenAuthorizationPage() { store.reopenAuthorizationPage(); error = store.error }

    func connect() async {
        guard !busy else { return }
        busy = true; error = nil; connected = false
        defer { busy = false }
        status = "正在连接 Notion 官方服务…"
        store.error = nil
        if store.hasSavedAuthorization { await store.connect() }
        guard !Task.isCancelled else { status = "已取消连接"; return }
        if !store.connected {
            await store.authorize()
            guard !Task.isCancelled else { store.error = nil; status = "已取消连接"; return }
            guard store.error == nil else { error = store.error; status = "Notion 授权未完成"; return }
            await store.connect()
        }
        guard !Task.isCancelled else { status = "已取消连接"; return }
        await identify()
    }
    /// 只验证保存过的工作区，不在启动或切换页面时弹出新的OAuth。
    func restore() async {
        guard !busy, defaults.dictionary(forKey: metadataKey) != nil else { return }
        busy = true; defer { busy = false }
        store.error = nil
        await store.connect()
        await identify()
    }
    private func identify() async {
        guard store.connected else { error = store.error; status = "Notion 尚未连接"; return }
        do {
            let tools = try Self.contract(store.tools)
            let identity = try Self.identity(try await store.readAccount(using: tools.identity))
            workspaceID = identity.id
            accountDisplay = identity.display
            store.configuration.tool = tools.create.name
            store.configuration.argumentTemplate = try Self.template(tools.create)
            store.error = nil
            store.saveSyncAction()
            guard store.error == nil else { throw MCPError.message("Notion 连接信息未能安全保存。") }
            defaults.set(["workspaceID": workspaceID, "display": accountDisplay], forKey: metadataKey)
            connected = true; status = "已连接 · 保存为工作区私人页面"
        } catch { self.error = MCPConnectionStore.safeError(error); connected = false; status = "Notion 连接尚未就绪" }
    }
    func sync(title: String, text: String) async throws -> MCPSyncReceipt {
        guard connected, !busy, !workspaceID.isEmpty, store.configuration.endpoint == Self.endpoint else {
            throw MCPError.message("请先连接 Notion 工作区。")
        }
        busy = true; defer { busy = false }
        let tools = try Self.contract(store.tools)
        let current = try Self.identity(try await store.readAccount(using: tools.identity))
        guard current.id == workspaceID else {
            connected = false
            throw MCPError.message("Notion 工作区已改变，请重新确认连接后再同步。")
        }
        store.configuration.tool = tools.create.name
        store.configuration.argumentTemplate = try Self.template(tools.create)
        let receipt = try await store.sync(title: title, text: text)
        let pageURL = receipt.structuredContent.flatMap { Self.pageURL($0) } ?? Self.pageURLFromText(receipt.result)
        if let pageURL {
            status = "会议已保存到 Notion"
            return MCPSyncReceipt(tool: "Notion 私人页面", result: "会议页面已创建。工作区：" + accountDisplay, remoteURL: pageURL)
        }
        return MCPSyncReceipt(tool: "Notion 私人页面", result: "Notion 已返回创建结果，但未返回可确认的页面链接。请到工作区查看，勿重复同步。", remoteURL: nil,
            warning: "页面创建结果待核对，未自动重试。")
    }
    func disconnect() throws {
        try store.disconnect()
        defaults.removeObject(forKey: metadataKey)
        connected = false; workspaceID = ""; accountDisplay = ""; status = "已断开 Notion"
        // endpoint为公开常量，留待下一次点击连接；凭据已经由store清理。
        store.configuration.endpoint = Self.endpoint
    }

    static func contract(_ tools: [MCPTool]) throws -> (identity: MCPTool, create: MCPTool) {
        guard let identity = tools.first(where: { $0.name == "notion-get-self" }),
              identity.annotations?["readOnlyHint"] as? Bool == true,
              (identity.inputSchema["required"] as? [String] ?? []).isEmpty,
              let create = tools.first(where: { $0.name == "notion-create-pages" }),
              let properties = create.inputSchema["properties"] as? [String: Any],
              let pages = properties["pages"] as? [String: Any], pages["type"] as? String == "array",
              Set(create.inputSchema["required"] as? [String] ?? []).isSubset(of: ["pages"]) else {
            throw MCPError.message("该 Notion 工作区未提供当前版本需要的身份和私人建页接口，已停止同步；不需要手动配置工具。")
        }
        return (identity, create)
    }
    static func template(_ tool: MCPTool) throws -> String {
        let properties = tool.inputSchema["properties"] as? [String: [String: Any]] ?? [:]
        var parameters: [String: Any] = ["pages": [["properties": ["title": "{{title}}"], "content": "{{text}}"]]]
        if let mode = properties["creation_mode"], (mode["enum"] as? [String])?.contains("draft") == true { parameters["creation_mode"] = "draft" }
        // 官方文档：省略parent创建私人页面；不调用共享/发布接口。
        if properties["allow_async"]?["type"] as? String == "boolean" { parameters["allow_async"] = false }
        return String(decoding: try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]), as: UTF8.self)
    }
    static func identity(_ response: [String: Any]) throws -> (id: String, display: String) {
        var json = response["structuredContent"] as? [String: Any]
        if json == nil, let contents = response["content"] as? [[String: Any]] {
            for content in contents {
                if let text = content["text"] as? String, let data = text.data(using: .utf8),
                   let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { json = value; break }
            }
        }
        guard let json, let workspace = json["workspace"] as? [String: Any], let id = workspace["id"] as? String, !id.isEmpty,
              let user = json["user"] as? [String: Any], user["type"] as? String == "person" else {
            throw MCPError.message("Notion 尚未返回可验证的个人账号与工作区，请在官方授权页选择个人连接。")
        }
        let name = workspace["name"] as? String ?? ""
        let userName = user["name"] as? String ?? ""
        return (id, [name.isEmpty ? "已授权工作区" : name, userName].filter { !$0.isEmpty }.joined(separator: " · "))
    }
    static func pageURL(_ value: Any) -> URL? {
        if let dictionary = value as? [String: Any] {
            if let raw = dictionary["url"] as? String, let url = validPageURL(raw) { return url }
            for child in dictionary.values { if let url = pageURL(child) { return url } }
        } else if let array = value as? [Any] {
            for child in array { if let url = pageURL(child) { return url } }
        }
        return nil
    }
    static func pageURLFromText(_ text: String) -> URL? {
        if let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data), let url = pageURL(value) { return url }
        let expression = try? NSRegularExpression(pattern: #"https://[^\s<>\"\)]+"#)
        for match in expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            if let range = Range(match.range, in: text), let url = validPageURL(String(text[range])) { return url }
        }
        return nil
    }
    private static func validPageURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", let host = url.host,
              ["notion.so", "www.notion.so", "notion.site", "www.notion.site"].contains(host) || host.hasSuffix(".notion.so") || host.hasSuffix(".notion.site"),
              url.path.count > 1 else { return nil }
        return url
    }
}
