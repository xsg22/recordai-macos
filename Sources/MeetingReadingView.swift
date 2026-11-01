import SwiftUI

struct MeetingReadingView: View {
    @ObservedObject var state: AppState
    @State private var tab = "转写"
    @State private var showingWorkspace = false
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 4) {
                readingTab("转写", symbol: "doc.text")
                readingTab("时间线", symbol: "clock")
                readingTab("笔记与助手", symbol: "square.and.pencil")
            }.padding(4).background(RecordAITheme.tabs, in: RoundedRectangle(cornerRadius: 10))
            if state.recording { RecordingTransportView(state: state) }
            else if state.audio != nil { NativePlaybackBar(state: state) }
            switch tab {
            case "时间线": MeetingTimelineOverview(state: state)
            case "笔记与助手": MeetingWorkspaceView(state: state)
            default: RecordingCanvasView(state: state)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: state.selection) { tab = "转写"; showingWorkspace = false }
            .sheet(isPresented: $showingWorkspace) { MeetingWorkspaceView(state: state, close: { showingWorkspace = false }).padding(28).frame(width: 720) }
    }
    private func readingTab(_ title: String, symbol: String) -> some View {
        Button { if title == "笔记与助手" { showingWorkspace = true } else { tab = title } } label: {
            Label(title, systemImage: symbol).font(AppTypography.secondary.weight(tab == title ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(tab == title ? RecordAITheme.accent : .secondary)
                .background(tab == title ? RecordAITheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(tab == title ? .isSelected : [])
    }
}

struct MeetingTimelineOverview: View {
    @ObservedObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("会议时间线").font(AppTypography.heading)
                if let record = state.current, record.hasCurrentParagraphs {
                    ForEach(record.transcriptParagraphs) { paragraph in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 6) {
                                Circle().fill(RecordAITheme.accent).frame(width: 9, height: 9)
                                Rectangle().fill(RecordAITheme.border).frame(width: 1, height: 48)
                            }.padding(.top, 4)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    if let time = paragraph.start { Text(clock(time)).monospacedDigit().foregroundStyle(RecordAITheme.accent) }
                                    Text(record.paragraphSpeaker(paragraph)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { state.playTranscriptParagraph(paragraph) } label: { Image(systemName: "play.fill") }
                                        .disabled(!state.canPlayTranscriptParagraph(paragraph)).accessibilityLabel("播放时间线片段")
                                }.font(AppTypography.secondary)
                                Text(paragraph.text).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    RecordAIInfo(text: "带时间的转录段落会显示在这里。尚未生成时间信息，或全文编辑后旧时间信息已失效。")
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
