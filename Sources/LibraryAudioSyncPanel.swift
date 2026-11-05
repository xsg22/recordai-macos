#if os(iOS) || os(macOS)
import SwiftUI
struct LibraryAudioSyncPanel: View {
    @ObservedObject var engine: LibraryAudioSyncEngine
    var choices: [LibrarySyncChoice]
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(text("原音同步")).font(.headline)
            Text(text("原音随同步开关自动上传和下载，无需逐条选择；传输完成后会校验文件。" )).font(.caption).foregroundStyle(.secondary)
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
                Button(text("使用本机原音更新云端")) { Task { await engine.replaceCloud() } }.disabled(engine.busy || !engine.automaticEnabled)
                Button(text("保留云端原音")) { Task { await engine.useCloud() } }.disabled(engine.busy || !engine.automaticEnabled)
                Text(text("选择版本前，双方原件都会保留。")).font(.caption)
            } else if !engine.jobs.isEmpty {
                Button(text("重试原音传输")) { Task { await engine.retry() } }.disabled(engine.busy || !engine.automaticEnabled)
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
