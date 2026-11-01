import SwiftUI

private struct AccountCardHeader: View {
    let title: String
    let status: String
    let connected: Bool
    var notion = false
    var body: some View {
        HStack(spacing: 16) {
            Group {
                if notion { Text("N").font(.system(size: 25, weight: .medium)) }
                else { Image(systemName: "doc.text").font(.system(size: 23)) }
            }.foregroundStyle(RecordAITheme.accent).frame(width: 48, height: 48)
                .background(RecordAITheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(AppTypography.heading)
                Text(status).font(AppTypography.secondary).foregroundStyle(connected ? Color.green : RecordAITheme.muted)
            }
        }
    }
}

struct AccountConnectionPanel: View {
    @ObservedObject var state: AppState
    var compact = false
    var body: some View {
        Group {
            if compact { compactCard }
            else { switch state.syncDestination {
            case .dingtalk: DingTalkConnectionCard(account: state.dingTalkAccount, compact: compact)
            case .notion: NotionConnectionCard(account: state.notionAccount, compact: compact)
            case .feishu: FeishuConnectionCard(account: state.feishuAccount, compact: compact)
            } }
        }
    }
    private var compactCard: some View {
        RecordAICard(quiet: true) {
            HStack {
                Text(state.syncDestination.rawValue + " · " + identity).font(.system(size: 14, weight: .semibold))
                Spacer()
                Label(connected ? "已连接" : "尚未连接", systemImage: connected ? "checkmark" : "link")
                    .font(AppTypography.secondary).foregroundStyle(connected ? Color.green : RecordAITheme.muted)
            }.padding(.vertical, 18)
            Text("发送：录音名称、时间、时长和转录正文。原始音频不会发送。")
                .font(AppTypography.secondary).foregroundStyle(RecordAITheme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
        }
    }
    private var connected: Bool {
        switch state.syncDestination { case .dingtalk: return state.dingTalkAccount.connected; case .feishu: return state.feishuAccount.connected; case .notion: return state.notionAccount.connected }
    }
    private var identity: String {
        let value: String
        switch state.syncDestination { case .dingtalk: value = state.dingTalkAccount.accountDisplay; case .feishu: value = state.feishuAccount.accountDisplay; case .notion: value = state.notionAccount.accountDisplay }
        return value.isEmpty ? "我的文档" : value
    }
}

struct DingTalkConnectionCard: View {
    @ObservedObject var account: DingTalkAccountConnection
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AccountCardHeader(title: "钉钉 · 我的文档", status: account.status + (account.connected && !account.accountDisplay.isEmpty ? " · " + account.accountDisplay : ""), connected: account.connected)
            if !compact {
                Text("通过官方授权页面连接个人工作区。同步前会显示发送范围，原始音频保留在本机。")
                    .font(AppTypography.secondary).lineSpacing(6).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("同步后向钉钉“我”发送完成提醒", isOn: $account.notifySelf).disabled(account.busy)
                if account.identities.count > 1 {
                    Picker("保存账号", selection: Binding(get: { account.selectedProfile }, set: { account.selectAccount($0) })) {
                        ForEach(account.identities) { identity in Text(identity.display).tag(identity.profile) }
                    }
                }
                HStack {
                    if account.busy { ProgressView().controlSize(.small) }
                    Button(account.connected ? "检查连接" : "连接钉钉账号") { Task { await account.connect() } }
                        .buttonStyle(RecordAIPrimaryButtonStyle()).disabled(account.busy)
                    if account.connected { Button("解除关联") { account.disconnect() }.disabled(account.busy) }
                }
            }
        }.padding(.vertical, 12).padding(20).frame(maxWidth: .infinity, alignment: .leading).font(AppTypography.body).buttonStyle(RecordAISecondaryButtonStyle())
            .background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecordAITheme.border, lineWidth: 1))
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
            AccountCardHeader(title: "飞书 · 我的文档", status: account.status + (account.connected && !account.accountDisplay.isEmpty ? " · " + account.accountDisplay : ""), connected: account.connected)
            if !compact {
                Text("首次连接会在官方浏览器引导中初始化应用，再授权个人文档权限。无需手填 App ID 或密钥；企业可能要求管理员批准。")
                    .font(AppTypography.secondary).lineSpacing(6).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if account.busy { ProgressView().controlSize(.small) }
                    Button("检查授权状态") { Task { await account.checkAuthorization() } }
                        .buttonStyle(RecordAIPrimaryButtonStyle()).disabled(account.busy)
                    if !account.connected {
                        Button(account.hasPendingAuthorization ? "继续上次授权" : "连接飞书账号") { Task { await account.connect() } }
                            .disabled(account.busy)
                        if account.hasPendingAuthorization {
                            Button("重新申请…") { confirmNewAuthorization = true }.disabled(account.busy)
                        }
                    }
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).font(AppTypography.body).buttonStyle(RecordAISecondaryButtonStyle())
            .background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecordAITheme.border, lineWidth: 1))
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
            AccountCardHeader(title: "Notion · 私人会议页面", status: account.status + (account.connected && !account.accountDisplay.isEmpty ? " · " + account.accountDisplay : ""), connected: account.connected, notion: true)
            if !compact {
                Text("使用 Notion 官方授权页面连接工作区，会议保存为私人页面。同步前可预览正文，原始音频保留在本机。")
                    .font(AppTypography.secondary).lineSpacing(6).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if account.busy { ProgressView().controlSize(.small) }
                    Button(account.connected ? "检查 Notion 连接" : "连接 Notion 账号") { account.startConnection() }
                        .buttonStyle(RecordAIPrimaryButtonStyle()).disabled(account.busy)
                    if account.canReopenAuthorization { Button("再次打开授权页面") { account.reopenAuthorizationPage() } }
                    if account.busy { Button("取消等待") { account.cancelConnection() } }
                    if account.connected {
                        Button("断开") { do { try account.disconnect() } catch { account.error = MCPConnectionStore.safeError(error) } }.disabled(account.busy)
                    }
                }
            }
        }.padding(.vertical, 12).padding(20).frame(maxWidth: .infinity, alignment: .leading).font(AppTypography.body).buttonStyle(RecordAISecondaryButtonStyle())
            .background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecordAITheme.border, lineWidth: 1))
            .task { await account.restore() }
            .alert("Notion 连接", isPresented: Binding(get: { account.error != nil }, set: { if !$0 { account.error = nil } })) {
                Button("好的") { account.error = nil }
            } message: { Text(account.error ?? "") }
    }
}
