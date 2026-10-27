import Foundation
import SwiftUI

struct DingTalkIdentity: Codable, Identifiable {
    let profile: String
    let userName: String
    let corpName: String
    var id: String { profile }
    var display: String { userName + " · " + corpName }
}

@MainActor
final class DingTalkAccountConnection: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var status = "未连接"
    @Published var error: String?
    @Published private(set) var identities: [DingTalkIdentity] = []
    @Published var notifySelf: Bool {
        didSet { defaults.set(notifySelf, forKey: "personalDingTalk.notifySelf") }
    }
    var onProgress: ((String) -> Void)?
    @Published var selectedProfile: String
    var accountDisplay: String { identities.first { $0.profile == selectedProfile }?.display ?? "个人钉钉" }
    private let defaults: UserDefaults
    private let executable: URL?
    init(defaults: UserDefaults = .standard, executable: URL? = Bundle.main.url(forResource: "dws", withExtension: nil, subdirectory: "Accounts")) {
        self.defaults = defaults; self.executable = executable
        notifySelf = defaults.object(forKey: "personalDingTalk.notifySelf") == nil ? true : defaults.bool(forKey: "personalDingTalk.notifySelf")
        selectedProfile = defaults.string(forKey: "personalDingTalk.profile") ?? ""
    }
    func restore() async {
        guard !busy, !defaults.bool(forKey: "personalDingTalk.detached") else { return }
        do { try await identify() } catch { connected = false; status = "未连接，请登录钉钉" }
    }
    func connect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        defaults.set(false, forKey: "personalDingTalk.detached")
        do {
            guard let executable else { throw MCPError.message("安装包缺少钉钉账号组件，请安装完整版本。") }
            // 已有有效账号直接复用官方CLI授权；不读取或导出token。
            do { try await identify(); if connected { return } } catch { }
            status = "请在浏览器中登录并授权钉钉…"
            _ = try await AccountCommandRunner.run(executable: executable, arguments: ["auth", "login", "--format", "json"])
            try await identify()
            guard connected else { throw MCPError.message("请从已登录账号中选择保存会议的账号。") }
        } catch { connected = false; self.error = MCPConnectionStore.safeError(error); status = "连接未完成" }
    }
    func selectAccount(_ profile: String) {
        guard identities.contains(where: { $0.profile == profile }) else { return }
        selectedProfile = profile; defaults.set(profile, forKey: "personalDingTalk.profile")
        connected = true; status = "已连接 · 保存到我的钉钉文档"
    }
    private func identify() async throws {
        guard let executable else { throw MCPError.message("缺少钉钉账号组件。") }
        let response = try await AccountCommandRunner.run(executable: executable, arguments: ["profile", "list", "--format", "json"])
        guard let rows = response["profiles"] as? [[String: Any]] else { throw MCPError.message("无法读取钉钉账号。") }
        identities = rows.compactMap { row in
            guard row["status"] as? String == "active", let profile = row["profile"] as? String,
                  let name = row["userName"] as? String, let corp = row["corpName"] as? String else { return nil }
            return DingTalkIdentity(profile: profile, userName: name, corpName: corp)
        }
        if !identities.contains(where: { $0.profile == selectedProfile }) {
            selectedProfile = rows.first(where: { $0["isCurrent"] as? Bool == true && $0["status"] as? String == "active" })?["profile"] as? String ?? ""
        }
        guard identities.contains(where: { $0.profile == selectedProfile }) else {
            connected = false; status = identities.isEmpty ? "未登录钉钉" : "请选择保存会议的账号"; return
        }
        let auth = try await AccountCommandRunner.run(executable: executable, arguments: ["auth", "status", "--profile", selectedProfile, "--format", "json"])
        guard auth["authenticated"] as? Bool == true,
              auth["token_valid"] as? Bool == true || auth["refresh_token_valid"] as? Bool == true else {
            connected = false; status = "登录已过期，请重新授权"; return
        }
        selectAccount(selectedProfile)
    }
    func sync(title: String, text: String) async throws -> MCPSyncReceipt {
        guard connected, !busy, let executable, identities.contains(where: { $0.profile == selectedProfile }) else { throw MCPError.message("请先连接钉钉账号。") }
        busy = true; defer { busy = false }
        let profile = selectedProfile
        let response = try await AccountCommandRunner.run(executable: executable,
            arguments: ["doc", "+create", "--name", title, "--content", "-", "--doc-format", "markdown", "--profile", profile, "--format", "json"], input: Data(text.utf8))
        guard response["ok"] as? Bool == true, let data = response["data"] as? [String: Any],
              let id = data["nodeId"] as? String, !id.isEmpty else { throw MCPError.message("钉钉未返回文档标识，结果尚未确认，请勿重复点击以免重复创建。") }
        onProgress?("钉钉文档已创建，正在确认内容…")
        var warning: String?
        var url = DingTalkSyncResult.documentURL(response)
        do {
            let read = try await AccountCommandRunner.run(executable: executable,
                arguments: ["doc", "+fetch", "--node", id, "--profile", profile, "--timeout", "20", "--format", "json"])
            let visible = Self.strings(read).joined(separator: "\n")
            let expected = text.split(separator: "\n").last.map { String($0.prefix(32)) } ?? ""
            guard !expected.isEmpty, visible.contains(expected) else { throw MCPError.message("文档内容尚未确认。") }
            if url == nil { url = DingTalkSyncResult.documentURL(read) }
        } catch { warning = "文档已创建，内容回读暂未确认；请到我的文档核对，不要重复同步。" }
        if url == nil {
            if let metadata = try? await AccountCommandRunner.run(executable: executable,
                arguments: ["drive", "info", "--node", id, "--profile", profile, "--timeout", "20", "--format", "json"]) {
                url = DingTalkSyncResult.documentURL(metadata)
            }
        }
        var notification = "未启用钉钉消息提醒"
        if notifySelf {
            onProgress?("钉钉文档已保存，正在通知钉钉“我”…")
            do {
                // 再读当前profile身份，不能用全局当前账号或显示名称猜收件人。
                let auth = try await AccountCommandRunner.run(executable: executable,
                    arguments: ["auth", "status", "--profile", profile, "--format", "json"])
                let args = try DingTalkSyncResult.notificationArguments(auth: auth, profile: profile, title: title,
                    url: url, idempotencyKey: "cohear-doc-" + id)
                let sent = try await AccountCommandRunner.run(executable: executable, arguments: args)
                notification = DingTalkSyncResult.notificationDescription(sent)
            } catch { notification = "提醒未发送或结果未确认；文档已保存，请勿重复同步。" }
        }
        status = warning == nil ? "已保存到我的钉钉文档" : "文档已创建，待核对内容"
        return MCPSyncReceipt(tool: "钉钉个人文档", result: "文档已创建。\n" + notification,
                             remoteURL: url, warning: warning, notificationStatus: notification)
    }

    func disconnect() {
        // 只解除本软件关联，不退出用户在官方CLI或其他应用中的账号。
        defaults.removeObject(forKey: "personalDingTalk.profile")
        defaults.set(true, forKey: "personalDingTalk.detached")
        selectedProfile = ""; identities = []; connected = false; status = "已解除本软件账号关联"
    }
    private static func strings(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(strings) }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(strings) }
        return []
    }
}
