import SwiftUI

struct RecordingSourceToggle: View {
    @ObservedObject var state: AppState
    let kind: MeetingAudioTrack.Kind
    var compact = false
    @State private var issue: String?
    private var title: String { L10n.text(kind == .microphone ? "麦克风" : "系统声音") }
    private var enabled: Bool { state.activeRecordingSources.contains(kind) }
    private var switching: Bool { state.switchingRecordingSource == kind }
    private var description: String { title + " · " + L10n.text(switching ? "切换中" : enabled ? "开" : "关") }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Group {
                    if switching { ProgressView().controlSize(.mini) }
                    else { Image(systemName: kind == .microphone ? "mic" : "desktopcomputer") }
                }.frame(width: 16, height: 16)
                if !compact {
                    Text(title)
                    Text(L10n.text(enabled ? "开" : "关")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.font(.system(size: 12, weight: .medium))
                .frame(width: compact ? 30 : nil, height: compact ? 32 : 36)
                .padding(.horizontal, compact ? 0 : 10)
                .foregroundStyle(enabled ? TalkTuckTheme.accent : TalkTuckTheme.ink)
                .background(enabled ? TalkTuckTheme.selection : TalkTuckTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(TalkTuckTheme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(description).accessibilityLabel(description)
            .disabled(!state.recording || state.preparing || state.quitting || state.recordingIssue != nil || state.switchingRecordingSource != nil)
            .popover(isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.headline)
                    Text(L10n.text(issue ?? "")).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.text("关闭")) { issue = nil }
                        Spacer()
                        Button(L10n.text("重试"), action: toggle)
                    }
                }.padding(18).frame(width: 300)
            }
    }
    private func toggle() {
        issue = nil
        Task { @MainActor in
            do { try await state.toggleRecordingSource(kind) }
            catch is CancellationError { }
            catch { issue = error.localizedDescription }
        }
    }
}
