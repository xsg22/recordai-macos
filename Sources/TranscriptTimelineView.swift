import AppKit
import SwiftUI

/// 统一阅读面：已定稿段落 + 本次实时片段；历史预览只在用户主动选择时展示。
struct TranscriptTimelineView: View {
    @ObservedObject var state: AppState
    @State private var history = false
    @State private var following = true
    @State private var editing: TranscriptParagraph?
    @State private var renaming: String?
    private let accent = RecordAITheme.accent
    private var showingLive: Bool { state.recording || state.preparing || (state.busy && state.transcriptPhase == .recognizing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.preparing || state.transcriptPhase == .failed { stageBanner }
            if history || state.editingTranscript {
            HStack {
                if !state.liveText.isEmpty || !(state.current?.liveUtterances.isEmpty ?? true) {
                Picker("转写来源", selection: $history) {
                    Text("正文").tag(false); Text("实时历史").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240).controlSize(.regular)
                }
                Spacer()
                if showingLive || history {
                    Toggle("跟随最新", isOn: $following).toggleStyle(.checkbox).font(AppTypography.secondary)
                } else {
                    Button(state.editingTranscript ? "完成编辑" : "编辑全文") { state.editingTranscript.toggle() }.disabled(state.busy)
                }
            }
            }
            if !history && state.editingTranscript && !showingLive { fullEditor }
            else { timeline.padding(.top, showingLive ? 10 : 0) }
            if let record = state.current, !record.speakerAnalysisMessage.isEmpty, !showingLive && !history {
                Text(record.speakerAnalysisMessage).font(AppTypography.secondary).foregroundStyle(.secondary).lineLimit(3)
            }
            if !state.recording && !(state.current?.subtitles.isEmpty ?? true) && !history {
                DisclosureGroup("原始字幕与时间戳") {
                    ScrollView { Text(state.current?.subtitles ?? "").font(.system(size: 15, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 100)
                }.font(AppTypography.secondary)
            }
        }
        .contextMenu {
            Toggle("查看实时历史", isOn: $history)
            Toggle("跟随最新", isOn: $following)
        }
        .onChange(of: state.selection) { history = false; state.editingTranscript = false; following = true }
        .onChange(of: state.recording) { if state.recording { history = false; following = true; state.editingTranscript = false } }
        .onChange(of: history) { following = !history }
        .sheet(item: $editing) { paragraph in
            TranscriptParagraphEditor(paragraph: paragraph, speakerName: state.current?.paragraphSpeaker(paragraph) ?? "", cancel: { editing = nil }, save: { updated in
                let success = state.editTranscriptParagraph(paragraph.id, text: updated)
                if success { editing = nil }; return success
            })
        }
        .sheet(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            if let id = renaming, let record = state.current {
                SpeakerEditor(record: record, speakerID: id, cancel: { renaming = nil }) { value, target in
                    guard state.selection == record.id else { return false }
                    let success = state.renameSpeaker(id, name: value, mergeInto: target)
                    if success { renaming = nil }; return success
                }
            }
        }
    }
    private var stageBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            if state.busy || state.preparing { ProgressView().controlSize(.small) }
            else { Image(systemName: state.recording ? "waveform" : state.current?.status == .completed ? "checkmark.circle.fill" : "text.alignleft").foregroundStyle(accent) }
            VStack(alignment: .leading, spacing: 3) {
                Text(stageTitle).font(AppTypography.body.weight(.medium))
                Text(stageDetail).font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    private var stageTitle: String {
        if state.recording { return state.paused ? "录音已暂停" : "正在实时识别" }
        if state.preparing { return "正在保存录音" }
        if state.busy {
            switch state.transcriptPhase {
            case .diarizing: return "正在区分发言人"
            case .aligning: return "正在对齐发言人与文字"
            default: return "正在生成最终文字"
            }
        }
        return state.current?.status == .completed ? "转录已保存" : "等待转录"
    }
    private var stageDetail: String {
        if state.recording && state.paused {
            return state.canRetryMicrophone
                ? "麦克风可能已断开。重新连接后点击“重试并继续”；已有录音会保留。"
                : (state.recordingIssue == nil ? "采集已暂停，已有文字保留；继续后接着记录。" : "已有原轨保留，请停止并保存后检查输入设备。")
        }
        if state.recording || state.preparing {
            return state.activeRecordingSessionMode == .continuous
                ? "录音继续；片段关闭后依次定稿并区分发言人。"
                : "文字持续出现，停止后生成定稿和发言人标签。"
        }
        if state.busy && [.diarizing, .aligning].contains(state.transcriptPhase) { return "正文已保存；分析可取消，不影响已有文字。" }
        if state.busy { return "正在核对录音中的语音片段，实时历史仍可回看。" }
        if state.current?.status == .interrupted, state.audio == nil { return "原文已保留；检查原轨可恢复未保存的音频。" }
        if state.current?.pendingAudioFiles.isEmpty == false { return "已有音频可回放；继续转录仅处理未完成片段。" }
        return "点击正文或时间播放本段，播完自动暂停；播放器可连续回放。"
    }
    private var timeline: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if history { historyRows }
                        else {
                            finalRows
                            if showingLive { currentLiveRows }
                        }
                        Color.clear.frame(height: 1).id("transcript-tail")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .background(UserScrollDetector { following = false })
                }
                if !following && (showingLive || history) {
                    Button { following = true; proxy.scrollTo("transcript-tail", anchor: .bottom) } label: { Label("回到最新", systemImage: "arrow.down") }
                        .buttonStyle(.bordered).padding(6).background(.regularMaterial, in: Capsule())
                }
            }
            .onChange(of: state.liveText) { if following && (showingLive || history) { proxy.scrollTo("transcript-tail", anchor: .bottom) } }
            .onChange(of: following) { if following { proxy.scrollTo("transcript-tail", anchor: .bottom) } }
        }
    }
    @ViewBuilder private var finalRows: some View {
        if let record = state.current, record.hasCurrentParagraphs {
            ForEach(record.transcriptParagraphs) { paragraph in paragraphRow(paragraph, record: record) }
        } else if !state.text.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                if showingLive { Text("已有定稿").font(AppTypography.secondary).foregroundStyle(.secondary) }
                Text(state.text).font(AppTypography.transcript).lineSpacing(7).textSelection(.enabled)
                if !(state.current?.transcriptParagraphs.isEmpty ?? true) { Text("全文已编辑，旧的发言人分段未同步；可重新转录生成新分段。").font(AppTypography.secondary).foregroundStyle(.secondary) }
            }
        } else if !showingLive { Text("录音或导入音频后，转录正文会显示在这里。").font(AppTypography.body).foregroundStyle(.secondary).padding(.vertical, 18) }
    }
    private func paragraphRow(_ paragraph: TranscriptParagraph, record: MeetingRecord) -> some View {
        HStack(alignment: .top, spacing: 18) {
                if let time = paragraph.start {
                    Button(clock(time)) { state.playTranscriptParagraph(paragraph) }
                        .buttonStyle(.plain).font(AppTypography.secondary.monospacedDigit()).foregroundStyle(RecordAITheme.muted)
                        .frame(width: 46, height: 28).contentShape(Rectangle())
                        .disabled(!state.canPlayTranscriptParagraph(paragraph))
                        .help("播放这一段，结束后自动暂停")
                }
            VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text(avatar(paragraph, record: record)).font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 26, height: 26).background(RecordAITheme.avatar, in: Circle()).accessibilityHidden(true)
                if let id = paragraph.speakerIDs.first, paragraph.speakerIDs.count == 1 {
                    speakerMenu(id, record: record)
                } else {
                    Text(record.paragraphSpeaker(paragraph)).font(AppTypography.body.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if showingLive || !state.liveText.isEmpty || !(state.current?.liveUtterances.isEmpty ?? true) {
                        Toggle("查看实时历史", isOn: $history)
                        Toggle("跟随最新", isOn: $following)
                        Divider()
                    }
                    Button("编辑这段") { editing = paragraph }.disabled(state.locked)
                    Menu("修改这段发言人") {
                        let ids = Array(Set((Array(record.speakerNames.keys) + record.transcriptParagraphs.flatMap(\.speakerIDs)).map { record.canonicalSpeaker($0) })).sorted()
                        ForEach(ids, id: \.self) { id in
                            Button(record.speakerName(id)) { state.assignParagraphSpeaker(paragraph.id, speakerID: id) }
                        }
                        Divider()
                        Button("标为发言人未确定") { state.assignParagraphSpeaker(paragraph.id, speakerID: nil) }
                    }.disabled(state.locked)
                    if paragraph.previousSpeakerIDs != nil {
                        Button("撤销本段发言人修改") { state.undoParagraphSpeaker(paragraph.id) }.disabled(state.locked)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).fixedSize().help("编辑文字或修改本段发言人")
            }
            Group {
                if state.canPlayTranscriptParagraph(paragraph) {
                    Button { state.playTranscriptParagraph(paragraph) } label: { paragraphText(paragraph) }.buttonStyle(.plain)
                        .help("点击播放本段，播完自动暂停；文字校正请使用段落菜单")
                        .accessibilityLabel("播放本段：" + paragraph.text)
                } else { paragraphText(paragraph).textSelection(.enabled) }
            }
                .contextMenu {
                    Button("复制这段文字") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paragraph.text, forType: .string)
                    }
                    Button("编辑这段") { editing = paragraph }.disabled(state.locked)
                }
            }
        }.padding(.vertical, 17)
            .background(state.playingParagraphID == paragraph.id ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    private func paragraphText(_ paragraph: TranscriptParagraph) -> some View {
        Text(paragraph.text).font(.system(size: 16)).lineSpacing(8).foregroundStyle(RecordAITheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func avatar(_ paragraph: TranscriptParagraph, record: MeetingRecord) -> String {
        guard let id = paragraph.speakerIDs.first else { return "?" }
        let ids = Set(record.speakerNames.keys.map { record.canonicalSpeaker($0) }).sorted()
        return ids.firstIndex(of: record.canonicalSpeaker(id)).map { String($0 + 1) } ?? "?"
    }
    private func speakerMenu(_ id: String, record: MeetingRecord) -> some View {
        let canonical = record.canonicalSpeaker(id)
        let others = record.speakerNames.keys.filter { record.canonicalSpeaker($0) == $0 && $0 != canonical }.sorted()
        return Menu {
            if canonical != id { Button("恢复独立发言人标签") { state.unmergeSpeaker(id) } }
            Button("修改名称…") { renaming = canonical }
            if !others.isEmpty {
                Menu("合并到") { ForEach(others, id: \.self) { target in Button(record.speakerName(target)) { state.mergeSpeaker(canonical, into: target) } } }
            }
        } label: { Text(record.speakerName(canonical)).font(AppTypography.body.weight(.medium)).lineLimit(1).truncationMode(.tail).frame(minHeight: 28) }
            .menuStyle(.borderlessButton).tint(RecordAITheme.ink).foregroundStyle(RecordAITheme.ink).fixedSize().help("修改名称或合并同一人的发言")
    }
    @ViewBuilder private var currentLiveRows: some View {
        if !state.text.isEmpty { Divider(); Text("本次实时识别 · 未定稿").font(AppTypography.secondary).foregroundStyle(.secondary) }
        ForEach(state.recordingLiveUtterances) { row in liveRow(row) }
        if !state.livePartial.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("正在识别 · 可能修订").font(AppTypography.secondary).foregroundStyle(.secondary)
                Text(state.livePartial).font(AppTypography.transcript).lineSpacing(7).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        } else if state.recordingLiveUtterances.isEmpty {
            Text(state.liveStatus.isEmpty ? "等待语音，识别文字会持续出现…" : state.liveStatus).font(AppTypography.body).foregroundStyle(.secondary).padding(.vertical, 12)
        }
    }
    @ViewBuilder private var historyRows: some View {
        Text("录音时的识别记录 · 未定稿，不用于导出和同步").font(AppTypography.secondary).foregroundStyle(.secondary)
        if let record = state.current, !record.liveUtterances.isEmpty {
            if !record.legacyLiveText.isEmpty {
                Text("之前的实时记录").font(AppTypography.secondary).foregroundStyle(.secondary)
                Text(record.legacyLiveText).font(AppTypography.transcript).lineSpacing(7).textSelection(.enabled)
                Divider()
            }
            ForEach(record.liveUtterances) { row in liveRow(row) }
            if state.recording && !state.livePartial.isEmpty { Text(state.livePartial).font(AppTypography.transcript).foregroundStyle(.secondary) }
        } else {
            Text(state.liveText.isEmpty ? "这场会议没有实时识别历史。" : state.liveText).font(AppTypography.transcript).lineSpacing(7).textSelection(.enabled)
        }
    }
    private func liveRow(_ row: LiveUtterance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(clock(row.start)).font(AppTypography.secondary.monospacedDigit()).foregroundStyle(.secondary)
            Text(row.text).font(AppTypography.transcript).lineSpacing(7).textSelection(.enabled)
        }
    }
    private var fullEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("修改全文后，旧的发言人分段可能无法对应。少量纠错建议在段落菜单里编辑。").font(AppTypography.secondary).foregroundStyle(.secondary)
            TextEditor(text: $state.text).font(AppTypography.transcript).lineSpacing(7)
                .scrollContentBackground(.hidden).disabled(state.locked).onChange(of: state.text) { state.scheduleSave() }
        }
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct TranscriptParagraphEditor: View {
    let cancel: () -> Void
    let save: (String) -> Bool
    private let paragraph: TranscriptParagraph
    private let speakerName: String
    @State private var failed = false
    @State private var draft: String
    init(paragraph: TranscriptParagraph, speakerName: String = "", cancel: @escaping () -> Void, save: @escaping (String) -> Bool) {
        self.cancel = cancel; self.save = save; self.paragraph = paragraph; self.speakerName = speakerName
        _draft = State(initialValue: paragraph.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RecordAIPageHeader(title: "编辑这段文字", subtitle: "保留录音时间和发言人标签。") { Button("取消", action: cancel).keyboardShortcut(.cancelAction) }
            TextEditor(text: $draft).font(AppTypography.body).lineSpacing(6).padding(12)
                .scrollContentBackground(.hidden).background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RecordAITheme.border, lineWidth: 1))
                .accessibilityLabel("段落正文")
            if failed { RecordAIInfo(text: "尚未保存，输入仍保留，请重试。", warning: true) }
            HStack {
                if let start = paragraph.start, let end = paragraph.end {
                    Text(String(format: "%02d:%02d—%02d:%02d", Int(start) / 60, Int(start) % 60, Int(end) / 60, Int(end) % 60) + (speakerName.isEmpty ? "" : " · " + speakerName)).font(AppTypography.secondary).foregroundStyle(.secondary)
                }
                Spacer(); Button("保存") { failed = !save(draft) }.buttonStyle(RecordAIPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 720, height: 446).buttonStyle(RecordAISecondaryButtonStyle())
    }
}

private struct UserScrollDetector: NSViewRepresentable {
    let onScroll: () -> Void
    func makeNSView(context: Context) -> Detector { let view = Detector(); view.onScroll = onScroll; return view }
    func updateNSView(_ nsView: Detector, context: Context) { nsView.onScroll = onScroll }
    final class Detector: NSView {
        var onScroll: (() -> Void)?
        private var observer: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { [weak self] notice in
                    guard let self, let scroll = notice.object as? NSScrollView, self.enclosingScrollView === scroll else { return }
                    self.onScroll?()
                }
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
