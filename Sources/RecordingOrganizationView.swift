import SwiftUI

struct RecordingOrganizationPanel: View {
    @ObservedObject var state: AppState
    @State private var managing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("录音整理", systemImage: "folder").font(AppTypography.heading)
                Spacer()
                Button { managing = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("管理分组")
            }
            if let record = state.current {
                Picker("分组", selection: Binding(get: { state.organization.group(record.groupID)?.id.uuidString ?? "" }, set: { _ = state.setGroup(UUID(uuidString: $0), recordIDs: [record.id]) })) {
                    Text("未分组").tag("")
                    ForEach(state.organization.groups) { Text($0.name).tag($0.id.uuidString) }
                }.pickerStyle(.menu).disabled(state.locked)

            }
        }.sheet(isPresented: $managing) { CollectionManager(state: state) }
    }
}

struct CollectionManager: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var message = ""
    @State private var removing: RecordingCollection?
    private var rows: [RecordingCollection] { state.organization.groups }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RecordAIPageHeader(title: "管理分组", subtitle: "将录音归档到分组。移除分组后录音回到未分组，原音和正文保留。") { Button("完成") { dismiss() } }
            HStack {
                TextField(editingID == nil ? "新建名称（最多 40 字）" : "修改名称", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
                Button(editingID == nil ? "创建" : "保存名称", action: save).disabled(state.locked || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editingID != nil { Button("取消修改") { editingID = nil; name = "" } }
            }
            if !message.isEmpty { Text(message).font(AppTypography.secondary).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if rows.isEmpty { Text("还没有分组").foregroundStyle(.secondary).padding(30) }
                    ForEach(rows) { row in
                        HStack {
                            Label(row.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                            Button("重命名") { editingID = row.id; name = row.name }
                            Button("移除") { removing = row }
                        }.padding(12).background(RecordAITheme.tabs, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }.padding(28).frame(width: 620, height: 480).buttonStyle(RecordAISecondaryButtonStyle())
            .alert("移除这个分组？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("取消", role: .cancel) { removing = nil }
                Button("移除分类") {
                    if let row = removing, state.removeCollection(row.id) {
                        if editingID == row.id { editingID = nil; name = "" }
                    } else { message = "移除失败，原分类仍保留，请重试。" }
                    removing = nil
                }
            } message: { Text("录音、音频和转录不会被删除。回收站中的关联也会解除。") }
    }
    private func save() {
        if state.saveCollection(name: name, id: editingID, inlineErrors: true) { name = ""; editingID = nil; message = "" }
        else { message = state.organizationIssue ?? "未保存。请检查名称或本地目录是否可写。" }
    }
}
