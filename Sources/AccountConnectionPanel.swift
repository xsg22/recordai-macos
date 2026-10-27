import SwiftUI

struct AccountConnectionPanel: View {
    @ObservedObject var state: AppState
    var compact = false
    var body: some View {
        Group {
            switch state.syncDestination {
            case .dingtalk: DingTalkConnectionCard(account: state.dingTalkAccount, compact: compact)
            case .notion: NotionConnectionCard(account: state.notionAccount, compact: compact)
            case .feishu: FeishuConnectionCard(account: state.feishuAccount, compact: compact)
            }
        }
    }
}

struct DingTalkConnectionCard: View {
    @ObservedObject var account: DingTalkAccountConnection
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("钉钉 · 我的文档", systemImage: "doc.text").font(.system(size: 20, weight: .semibold))
            Text(account.status).foregroundStyle(account.connected ? Color.green : Color.secondary)
            if account.connected { Text(account.accountDisplay).font(AppTypography.body) }
            if !compact {
                Text("登录后自动识别你的账号。会议以在线文档保存，不会通过机器人群发。首次保存时可能需要补充文档权限授权。")
                    .foregroundStyle(.secondary)
                Toggle("同步后向钉钉“我”发送完成提醒", isOn: $account.notifySelf).disabled(account.busy)
                if account.identities.count > 1 {
                    Picker("保存账号", selection: Binding(get: { account.selectedProfile }, set: { account.selectAccount($0) })) {
                        ForEach(account.identities) { identity in Text(identity.display).tag(identity.profile) }
                    }
                }
                HStack {
                    if account.busy { ProgressView().controlSize(.small) }
                    Button(account.connected ? "重新连接钉钉" : "连接钉钉账号") { Task { await account.connect() } }
                        .buttonStyle(.borderedProminent).disabled(account.busy)
                    if account.connected { Button("解除关联") { account.disconnect() }.disabled(account.busy) }
                }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).font(AppTypography.body).controlSize(.extraLarge)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .task { await account.restore() }
            .alert("钉钉连接", isPresented: Binding(get: { account.error != nil }, set: { if !$0 { account.error = nil } })) {
                Button("好的") { account.error = nil }
            } message: { Text(account.error ?? "") }
    }
}


struct FeishuConnectionCard: View {
    @ObservedObject var account: FeishuAccountConnection
    let compact: Bool
    @State private var confirmNewAuthorization = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("飞书 · 我的文档", systemImage: "doc.text").font(.system(size: 20, weight: .semibold))
            Text(account.status).foregroundStyle(account.connected ? Color.green : Color.secondary)
            if !account.accountDisplay.isEmpty { Text(account.accountDisplay).font(AppTypography.body) }
            if !compact {
                Text("首次连接会在官方浏览器引导中初始化应用，再授权个人文档权限。无需手填 App ID 或密钥；企业可能要求管理员批准。")
                    .foregroundStyle(.secondary)
                HStack {
                    if account.busy { ProgressView().controlSize(.small) }
                    Button("检查授权状态") { Task { await account.checkAuthorization() } }
                        .buttonStyle(.borderedProminent).disabled(account.busy)
                    if !account.connected {
                        Button(account.hasPendingAuthorization ? "继续上次授权" : "连接飞书账号") { Task { await account.connect() } }
                            .disabled(account.busy)
                        if account.hasPendingAuthorization {
                            Button("重新申请…") { confirmNewAuthorization = true }.disabled(account.busy)
                        }
                    }
                }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).font(AppTypography.body).controlSize(.extraLarge)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .task { await account.restore() }
            .confirmationDialog("重新发起飞书授权？", isPresented: $confirmNewAuthorization) {
                Button("重新申请授权") { Task { await account.requestNewAuthorization() } }
                Button("取消", role: .cancel) { }
            } message: { Text("先检查已有授权。只有上一次申请已失效或被取消时才需要重新申请；旧申请将不再继续使用。") }
            .alert("飞书连接", isPresented: Binding(get: { account.error != nil }, set: { if !$0 { account.error = nil } })) {
                Button("好的") { account.error = nil }
            } message: { Text(account.error ?? "") }
    }
}

struct DingTalkNotificationOption: View {
    @ObservedObject var account: DingTalkAccountConnection
    var disabled: Bool
    var body: some View {
        Toggle("文档保存后，向钉钉“我”发送标题和文档链接", isOn: $account.notifySelf).disabled(disabled)
    }
}

struct NotionConnectionCard: View {
    @ObservedObject var account: NotionAccountConnection
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Notion · 私人会议页面", systemImage: "doc.richtext").font(.system(size: 20, weight: .semibold))
            Text(account.status).foregroundStyle(account.connected ? Color.green : Color.secondary)
            if !account.accountDisplay.isEmpty { Text(account.accountDisplay).font(AppTypography.body) }
            if !compact {
                Text("使用 Notion 官方服务。点击连接后在浏览器登录并选择工作区；会议保存为私人页面，无需 Pipedream、API 密钥或工具配置。")
                    .foregroundStyle(.secondary)
                HStack {
                    if account.busy { ProgressView().controlSize(.small) }
                    Button(account.connected ? "检查 Notion 连接" : "连接 Notion 账号") { account.startConnection() }
                        .buttonStyle(.borderedProminent).disabled(account.busy)
                    if account.canReopenAuthorization { Button("再次打开授权页面") { account.reopenAuthorizationPage() } }
                    if account.busy { Button("取消等待") { account.cancelConnection() } }
                    if account.connected {
                        Button("断开") { do { try account.disconnect() } catch { account.error = MCPConnectionStore.safeError(error) } }.disabled(account.busy)
                    }
                }
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).font(AppTypography.body).controlSize(.extraLarge)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .task { await account.restore() }
            .alert("Notion 连接", isPresented: Binding(get: { account.error != nil }, set: { if !$0 { account.error = nil } })) {
                Button("好的") { account.error = nil }
            } message: { Text(account.error ?? "") }
    }
}
