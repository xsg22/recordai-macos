import SwiftUI

struct SpeakerEditor: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let record: MeetingRecord
    let speakerID: String
    let cancel: () -> Void
    let save: (String, String?) -> Bool
    @State private var name: String
    @State private var target = ""
    @State private var failed = false
    init(record: MeetingRecord, speakerID: String, cancel: @escaping () -> Void, save: @escaping (String, String?) -> Bool) {
        self.record = record; self.speakerID = speakerID; self.cancel = cancel; self.save = save
        _name = State(initialValue: record.speakerName(speakerID))
    }
    private var others: [String] {
        Set(record.speakerNames.keys.map { record.canonicalSpeaker($0) })
            .filter { $0 != record.canonicalSpeaker(speakerID) }.sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TalkTuckPageHeader(title: L10n.text("发言人名称"), subtitle: L10n.text("声音标签不会自动对应真实身份。")) { Button(L10n.text("取消"), action: cancel).keyboardShortcut(.cancelAction) }
            HStack { Text(L10n.text("当前标签")); Spacer(); Text(record.speakerName(speakerID)).foregroundStyle(.secondary) }
            TextField(L10n.text("发言人名称"), text: $name).textFieldStyle(.plain).padding(11).background(TalkTuckTheme.surface, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(TalkTuckTheme.border)).accessibilityLabel(L10n.text("发言人名称"))
            TalkTuckCard(quiet: true) {
                Text(L10n.text("合并到已有发言人")).font(AppTypography.heading)
                TalkTuckSettingRow(title: L10n.text("已有发言人")) {
                    TalkTuckChoicePicker(title: L10n.text("已有发言人"), items: [(L10n.text("不合并"), "")] + others.map { (record.speakerName($0), $0) }, selection: $target)
                }.padding(.vertical, 8)
                Text(L10n.text("合并后可从段落菜单恢复独立标签。")).font(AppTypography.secondary).foregroundStyle(.secondary)
            }
            if failed { TalkTuckInfo(text: L10n.text("保存失败，输入已保留，请重试。"), warning: true) }
            HStack { Button(L10n.text("取消"), action: cancel); Spacer(); Button(L10n.text("保存")) { failed = !save(name, target.isEmpty ? nil : target) }
                .buttonStyle(TalkTuckPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 720).font(AppTypography.body).buttonStyle(TalkTuckSecondaryButtonStyle())
    }
}
