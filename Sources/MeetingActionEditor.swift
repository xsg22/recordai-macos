import SwiftUI

struct MeetingActionList: View {
    @ObservedObject var state: AppState
    @State private var editing: MeetingActionItem?
    @State private var editingMeetingID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("行动项", systemImage: "checklist").font(AppTypography.heading)
                Text("\(state.current?.actionItems.count ?? 0)").font(AppTypography.secondary).foregroundStyle(.secondary)
                Spacer()
                Button("添加") { edit(MeetingActionItem(title: "")) }.buttonStyle(.plain).foregroundStyle(RecordAITheme.accent).disabled(state.locked)
            }
            ForEach(state.current?.actionItems ?? []) { item in
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        state.updateActionItems { items in
                            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].isDone.toggle() }
                        }
                    } label: { Image(systemName: item.isDone ? "checkmark.square.fill" : "square") }
                        .buttonStyle(.plain).foregroundStyle(item.isDone ? RecordAITheme.accent : .secondary)
                        .accessibilityLabel((item.isDone ? "标记未完成：" : "标记完成：") + item.title)
                    VStack(alignment: .leading, spacing: 5) {
                        Button { edit(item) } label: { Text(item.title).strikethrough(item.isDone).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                        if !item.assignee.isEmpty || item.dueDate != nil {
                            HStack {
                                if !item.assignee.isEmpty { Text(item.assignee) }
                                if let date = item.dueDate { Text(date, format: .dateTime.month().day()) }
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button("编辑") { edit(item) }
                        Button("移除行动项", role: .destructive) { state.updateActionItems { $0.removeAll { $0.id == item.id } } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("行动项操作")
                }.disabled(state.locked)
            }
            if state.current?.actionItems.isEmpty == true { Text("添加会议中的后续工作。").font(AppTypography.secondary).foregroundStyle(.secondary) }
        }.sheet(item: $editing) { item in
            MeetingActionEditor(item: item, cancel: { editing = nil }) { saved in
                guard state.current?.id == editingMeetingID else { return false }
                let success = state.updateActionItems { items in
                    if let index = items.firstIndex(where: { $0.id == saved.id }) { items[index] = saved }
                    else { items.append(saved) }
                }
                if success { editing = nil }
                return success
            }
        }.onChange(of: state.selection) { editing = nil; editingMeetingID = nil }
    }
    private func edit(_ item: MeetingActionItem) { editingMeetingID = state.current?.id; editing = item }
}

struct MeetingActionEditor: View {
    let cancel: () -> Void
    let save: (MeetingActionItem) -> Bool
    @State private var draft: MeetingActionItem
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var saveIssue = false
    init(item: MeetingActionItem, cancel: @escaping () -> Void, save: @escaping (MeetingActionItem) -> Bool) {
        self.cancel = cancel; self.save = save
        _draft = State(initialValue: item)
        _hasDueDate = State(initialValue: item.dueDate != nil)
        _dueDate = State(initialValue: item.dueDate ?? Date())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            RecordAIPageHeader(title: "编辑行动项", subtitle: "手动管理会议待办。") { Button("取消", action: cancel).keyboardShortcut(.cancelAction) }
            VStack(alignment: .leading, spacing: 0) {
                RecordAISettingRow(title: "事项") { TextField("事项", text: $draft.title).textFieldStyle(.plain).font(AppTypography.secondary).padding(11).background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(RecordAITheme.border)).accessibilityLabel("事项") }
                Divider()
                RecordAISettingRow(title: "负责人") { TextField("可选", text: $draft.assignee).textFieldStyle(.plain).font(AppTypography.secondary).padding(11).background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(RecordAITheme.border)).accessibilityLabel("负责人") }
                Divider()
                RecordAISettingRow(title: "截止日期") {
                    HStack {
                        Toggle("设置截止日期", isOn: $hasDueDate).labelsHidden().accessibilityLabel("设置截止日期")
                        if hasDueDate { DatePicker("截止日期", selection: $dueDate, displayedComponents: .date).labelsHidden() }
                    }
                }
                Divider()
                RecordAISettingRow(title: "完成状态", minimumHeight: 44) { Toggle(draft.isDone ? "已完成" : "尚未完成", isOn: $draft.isDone).accessibilityLabel("已完成") }
            }
            if saveIssue { RecordAIInfo(text: "行动项尚未保存，输入仍保留。请关闭错误提示后重试。", warning: true) }
            HStack {
                Button("取消", action: cancel)
                Spacer()
                Button("保存") {
                    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.assignee = draft.assignee.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.dueDate = hasDueDate ? dueDate : nil
                    saveIssue = !save(draft)
                }.buttonStyle(RecordAIPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 720).font(AppTypography.body)
            .buttonStyle(RecordAISecondaryButtonStyle())
    }
}
