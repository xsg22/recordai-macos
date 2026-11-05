#if os(iOS) || os(macOS)
import SwiftUI

struct LibrarySyncChoice: Identifiable { var id: UUID; var title: String; var isLocalFinal = false }
struct LibrarySyncPanel: View {
    @ObservedObject var engine: LibrarySyncEngine
    var choices: [LibrarySyncChoice]
    var groupNames: [UUID:String] = [:]
    @State private var selected = Set<UUID>()
    private func label(_ value: LibrarySyncValue?) -> String {
        if let record = value?.recording {
            let group = record.groupId.flatMap { groupNames[$0] } ?? L10nSync.text("未分组")
            return record.title + "\n" + L10nSync.text("分组") + ": " + group + "\n" + record.text
        }
        return value?.group?.name ?? L10nSync.text("已删除")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L10nSync.text("文字与分组同步")).font(.headline)
            Text(L10nSync.text("主动选择本地或云端定稿，同步正文、标题、发言人与分组。临时字幕不会上传，原音需单独选择。"))
                .font(.caption).foregroundStyle(.secondary)
            if !choices.isEmpty {
                DisclosureGroup(L10nSync.text("选择需要同步的定稿")) {
                    ForEach(choices) { row in
                        Toggle(row.title + (row.isLocalFinal ? " · " + L10nSync.text("本地定稿") : ""),isOn:Binding(get:{selected.contains(row.id)},set:{if $0 {selected.insert(row.id)} else {selected.remove(row.id)}}))
                    }
                }
            }
            HStack {
                Button(L10nSync.text(engine.enabled ? "同步选中录音" : "开启文字与分组同步")) { engine.enable(recordingIds:selected);selected.removeAll() }.disabled(engine.busy)
                if engine.enabled {
                    Button(L10nSync.text("立即同步")) { Task { await engine.synchronize() } }.disabled(engine.busy)
                    Button(L10nSync.text("暂停同步")) { engine.pause() }
                }
            }
            if engine.busy { ProgressView().controlSize(.small) }
            Text(L10nSync.text(engine.message)).font(.caption).foregroundStyle(.secondary)
            if engine.pendingCount > 0 { Text(L10nSync.text("离线修改已保留，联网后会重试。" )).font(.caption) }
            ForEach(engine.conflicts) { conflict in
                VStack(alignment:.leading,spacing:8) {
                    Text(conflict.title).font(.subheadline).bold()
                    DisclosureGroup(L10nSync.text("查看双方版本")) {
                        Text(L10nSync.text("本机版本")).font(.caption).bold()
                        Text(label(conflict.local)).textSelection(.enabled)
                        Text(L10nSync.text("云端版本")).font(.caption).bold()
                        Text(label(conflict.remote?.value)).textSelection(.enabled)
                    }
                    HStack {
                        Button(L10nSync.text("保留本机版本")) { engine.resolve(conflict.id,useLocal:true) }
                        Button(L10nSync.text("使用云端版本")) { engine.resolve(conflict.id,useLocal:false) }
                    }
                }.padding(12).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
            }
        }
    }
}
// Host apps keep their existing localization system and translation catalog.
private enum L10nSync {
    static func text(_ key:String) -> String {
        #if os(macOS)
        return L10n.text(key)
        #else
        return L10n.tr(key)
        #endif
    }
}

#endif
