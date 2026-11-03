import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var store: MCPConnectionStore
    @State private var bearer = ""
    @State private var actionID = ""
    @State private var recipient = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField(L10n.text("连接名称，例如：我的钉钉"), text: $store.configuration.name)
                SecureField(L10n.text("MCP Streamable HTTP 地址"), text: $store.configuration.endpoint)
                Text(L10n.text("完整地址可能包含身份凭据，仅保存在系统钥匙串。目标展示仅包含主机名。")).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L10n.text("服务方要求的授权范围（可选）")) {
                    TextField("OAuth scope", text: $store.configuration.scope)
                }
                HStack {
                    Button(L10n.text("保存配置")) { store.saveConfiguration() }
                    Button(L10n.text("浏览器授权")) { Task { await store.authorize() } }.disabled(store.busy)
                    Button(L10n.text("连接")) { Task { await store.connect() } }.disabled(store.busy)
                }
                Text(L10n.text(store.status)).foregroundStyle(store.connected ? .green : .secondary)
                DisclosureGroup(L10n.text("高级：服务提供的 Bearer 授权")) {
                    SecureField(L10n.text("访问令牌（仅存钥匙串）"), text: $bearer)
                    Button(L10n.text("保存授权")) {
                        do { try store.saveBearer(bearer); bearer = "" }
                        catch { store.error = MCPConnectionStore.safeError(error) }
                    }.disabled(bearer.isEmpty || store.busy)
                }
                Divider()
                Text(L10n.text("录音保存方式")).font(.headline)
                if !store.connected {
                    Text(L10n.text("连接后，软件会检查可用的个人保存方式。")).foregroundStyle(.secondary)
                } else if !store.personalActions.isEmpty {
                    Picker(L10n.text("保存到"), selection: $actionID) {
                        Text(L10n.text("选择保存方式")).tag("")
                        ForEach(store.personalActions) { action in Text(action.title).tag(action.id) }
                    }
                    if let action = store.personalActions.first(where: { $0.id == actionID }) {
                        if action.recipientField != nil { TextField(L10n.text("我的邮箱"), text: $recipient) }
                        Button(L10n.text("设为默认保存方式")) {
                            do {
                                store.configuration.tool = action.tool
                                store.configuration.argumentTemplate = try action.template(recipient: recipient)
                                store.saveSyncAction()
                            } catch { store.error = MCPConnectionStore.safeError(error) }
                        }
                    }
                } else {
                    Label(L10n.text("已连接，个人同步尚未就绪"), systemImage: "info.circle").font(.headline)
                    Text(L10n.text(store.capabilityExplanation)).foregroundStyle(.secondary)
                }
                DisclosureGroup(L10n.text("开发者选项：自定义服务适配")) {
                    VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("选择保存录音的工具")).font(.headline)
                Text(L10n.text("先核对工具说明与输入字段。只选择写入你个人空间或发给自己的工具，不要选择群广播、删除、公开分享等工具。")).font(.caption).foregroundStyle(.secondary)
                Picker(L10n.text("工具"), selection: $store.configuration.tool) {
                    Text(L10n.text("请选择工具")).tag("")
                    ForEach(store.tools) { tool in Text(tool.name).tag(tool.name) }
                }.disabled(!store.connected)
                if let tool = store.selectedTool {
                    Text(tool.description).textSelection(.enabled)
                    DisclosureGroup(L10n.text("工具输入 JSON Schema")) {
                        Text(schemaText(tool)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Text(L10n.text("参数模板")).font(.headline)
                Text(L10n.text("{{title}} 替换成录音标题，{{text}} 替换成录音正文。收件人、文件夹等目标必须在模板中明确填写；发送前可预览实际参数。")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.configuration.argumentTemplate).font(.system(.body, design: .monospaced)).frame(minHeight: 150).border(.quaternary)
                Button(L10n.text("保存同步动作")) { store.saveSyncAction() }.disabled(!store.connected || store.busy)
                Text(L10n.text("工具和模板修改在当前连接立即生效；修改服务地址后需重新连接。不会自动同步，也不会上传原始音频。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(L10n.text("移除本机授权")) { do { try store.disconnect() } catch { store.error = MCPConnectionStore.safeError(error) } }.disabled(store.busy)
                Text(L10n.text("授权兼容：支持标准 OAuth 发现、动态公共客户端注册和 PKCE 的服务可浏览器连接。其他服务可使用其提供的已授权 MCP 地址；没有可用服务时显示未连接。")).font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).padding(24)
        }.frame(minWidth: 600)
        .alert(L10n.text("连接提示"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L10n.text("知道了")) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func schemaText(_ tool: MCPTool) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: tool.inputSchema, options: [.prettyPrinted, .sortedKeys]) else { return "无法显示 Schema" }
        return String(decoding: data, as: UTF8.self)
    }
}
