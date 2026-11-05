#if os(iOS) || os(macOS)
import SwiftUI
struct LibraryAudioSyncPanel: View {
    @ObservedObject var engine: LibraryAudioSyncEngine
    var choices: [LibrarySyncChoice]
    @State private var selected: UUID?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(text("原音同步")).font(.headline)
            Text(text("仅同步已加入账号的录音。手动上传或下载，原件会保留；本地转录文字不会随音频上传。")).font(.caption).foregroundStyle(.secondary)
            Picker(text("选择录音"),selection:$selected) {
                Text(text("选择录音")).tag(UUID?.none)
                ForEach(choices) { row in Text(row.title).tag(Optional(row.id)) }
            }
            HStack {
                Button(text("上传本机原音")) { if let selected { Task { await engine.enqueue(selected,direction:.upload) } } }.disabled(selected == nil || engine.busy)
                Button(text("下载云端原音")) { if let selected { Task { await engine.enqueue(selected,direction:.download) } } }.disabled(selected == nil || engine.busy)
            }
            if engine.busy { ProgressView().controlSize(.small) }
            Text(text(engine.message)).font(.caption).foregroundStyle(.secondary)
            ForEach(engine.jobs) { job in
                HStack {
                    Text((job.direction == .upload ? text("上传") : text("下载"))+" · "+(choices.first { $0.id == job.recordingId }?.title ?? text("录音"))).font(.caption)
                    Spacer()
                    Button(text("移除任务")) { engine.remove(job.id) }.disabled(engine.busy)
                }
            }
            if engine.conflict != nil {
                Button(text("使用本机原音更新云端")) { Task { await engine.replaceCloud() } }.disabled(engine.busy)
                Text(text("也可移除上传任务，再选择下载云端原音。旧原件不会被删除。")).font(.caption)
            } else if !engine.jobs.isEmpty {
                Button(text("重试原音传输")) { Task { await engine.retry() } }.disabled(engine.busy)
            }
        }
    }
    private func text(_ key: String) -> String {
        #if os(macOS)
        return L10n.text(key)
        #else
        return L10n.tr(key)
        #endif
    }
}
#endif
