import SwiftUI

struct RecordingOrganizationPanel: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    @State private var managing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(L10n.text("录音整理"), systemImage: "folder").font(AppTypography.heading)
                Spacer()
                Button { managing = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel(L10n.text("管理分组"))
            }
            if let record = state.current {
                Picker(L10n.text("分组"), selection: Binding(get: { state.organization.group(record.groupID)?.id.uuidString ?? "" }, set: { _ = state.setGroup(UUID(uuidString: $0), recordIDs: [record.id]) })) {
                    Text(L10n.text("未分组")).tag("")
                    ForEach(state.organization.groups.filter { $0.userId == record.userId }) { Text($0.name).tag($0.id.uuidString) }
                }.pickerStyle(.menu).disabled(state.locked)

            }
        }.sheet(isPresented: $managing) { CollectionManager(state: state) }
    }
}

struct CollectionManager: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var message = ""
    @State private var removing: RecordingCollection?
    private var rows: [RecordingCollection] { state.organization.groups }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TalkTuckPageHeader(title: L10n.text("管理分组"), subtitle: L10n.text("创建后，右键录音选择“移动到分组”。移除分组不会删除录音。")) { Button(L10n.text("完成")) { dismiss() } }
            HStack {
                TextField(L10n.text(editingID == nil ? "新建名称（最多 40 字）" : "修改名称"), text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
                Button(L10n.text(editingID == nil ? "创建" : "保存名称"), action: save).disabled(state.locked || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editingID != nil { Button(L10n.text("取消修改")) { editingID = nil; name = "" } }
            }
            if !message.isEmpty { Text(L10n.text(message)).font(AppTypography.secondary).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if rows.isEmpty { Text(L10n.text("还没有分组")).foregroundStyle(.secondary).padding(30) }
                    ForEach(rows) { row in
                        HStack {
                            VStack(alignment:.leading) { Label(row.name, systemImage: "folder");Text(L10n.text(row.userId == nil ? "本机分组" : "账号分组")).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading)
                            Text(L10n.text("\(state.history.filter { $0.groupID == row.id }.count) 条录音")).foregroundStyle(.secondary)
                            Button(L10n.text("重命名")) { editingID = row.id; name = row.name }
                            Button(L10n.text("移除")) { removing = row }
                        }.padding(12).background(TalkTuckTheme.tabs, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }.padding(28).frame(width: 620, height: 480).buttonStyle(TalkTuckSecondaryButtonStyle())
            .alert(L10n.text("移除这个分组？"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(L10n.text("取消"), role: .cancel) { removing = nil }
                Button(L10n.text("移除分类")) {
                    if let row = removing, state.removeCollection(row.id) {
                        if editingID == row.id { editingID = nil; name = "" }
                    } else { message = "移除失败，原分类仍保留，请重试。" }
                    removing = nil
                }
            } message: { Text(L10n.text("录音、音频和转录不会被删除。回收站中的关联也会解除。")) }
    }
    private func save() {
        if state.saveCollection(name: name, id: editingID, inlineErrors: true) { name = ""; editingID = nil; message = "" }
        else { message = state.organizationIssue ?? "未保存。请检查名称或本地目录是否可写。" }
    }
}
