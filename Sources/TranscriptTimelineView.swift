import AppKit
import SwiftUI

/// 统一阅读面：已定稿段落 + 本次实时片段；历史预览只在用户主动选择时展示。
struct TranscriptTimelineView: View {
    @ObservedObject var state: AppState
    @State private var history = false
    @State private var following = true
    @State private var editingFull = false
    @State private var editing: TranscriptParagraph?
    @State private var renaming: String?
    @State private var name = ""
    private let accent = Color(red: 0.08, green: 0.35, blue: 0.95)
    private var showingLive: Bool { state.recording || state.preparing || (state.busy && state.transcriptPhase == .recognizing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            stageBanner
            HStack {
                Picker("转写来源", selection: $history) {
                    Text("正文").tag(false); Text("实时历史").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240).controlSize(.regular)
                Spacer()
                if showingLive || history {
                    Toggle("跟随最新", isOn: $following).toggleStyle(.checkbox).font(AppTypography.secondary)
                } else {
                    Button(editingFull ? "完成编辑" : "编辑全文") { editingFull.toggle() }.disabled(state.busy)
                }
            }
            if !history && editingFull && !showingLive { fullEditor }
            else { timeline }
            if let record = state.current, !record.speakerAnalysisMessage.isEmpty, !showingLive && !history {
                Text(record.speakerAnalysisMessage).font(AppTypography.secondary).foregroundStyle(.secondary).lineLimit(3)
            }
            if !state.recording && !(state.current?.subtitles.isEmpty ?? true) && !history {
                DisclosureGroup("原始字幕与时间戳") {
                    ScrollView { Text(state.current?.subtitles ?? "").font(.system(size: 15, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 100)
                }.font(AppTypography.secondary)
            }
        }
        .onChange(of: state.selection) { history = false; editingFull = false; following = true }
        .onChange(of: state.recording) { if state.recording { history = false; following = true; editingFull = false } }
        .onChange(of: history) { following = !history }
        .sheet(item: $editing) { paragraph in
            TranscriptParagraphEditor(paragraph: paragraph, cancel: { editing = nil }, save: { updated in
                state.editTranscriptParagraph(paragraph.id, text: updated); editing = nil
            })
        }
        .alert("发言人名称", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("例如：小王", text: $name)
            Button("保存") { if let id = renaming { state.renameSpeaker(id, name: name) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        } message: { Text("名称由你填写；声音标签不会自动对应真实身份。") }
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                if let time = paragraph.start {
                    Button(clock(time)) { state.playTranscriptParagraph(paragraph) }
                        .buttonStyle(.plain).font(AppTypography.secondary.monospacedDigit()).foregroundStyle(accent)
                        .frame(minHeight: 28).contentShape(Rectangle())
                        .disabled(!state.canPlayTranscriptParagraph(paragraph))
                        .help("播放这一段，结束后自动暂停")
                }
                if let id = paragraph.speakerIDs.first, paragraph.speakerIDs.count == 1 {
                    speakerMenu(id, record: record)
                } else {
                    Text(record.paragraphSpeaker(paragraph)).font(AppTypography.body.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
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
            Button { state.playTranscriptParagraph(paragraph) } label: {
                Text(paragraph.text).font(AppTypography.transcript).lineSpacing(7)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!state.canPlayTranscriptParagraph(paragraph))
                .help("点击播放本段，播完自动暂停；文字校正请使用段落菜单")
                .accessibilityLabel("播放本段：" + paragraph.text)
                .contextMenu {
                    Button("复制这段文字") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paragraph.text, forType: .string)
                    }
                    Button("编辑这段") { editing = paragraph }.disabled(state.locked)
                }
        }.padding(.vertical, 4).padding(.horizontal, 6)
            .background(state.playingParagraphID == paragraph.id ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    private func speakerMenu(_ id: String, record: MeetingRecord) -> some View {
        let canonical = record.canonicalSpeaker(id)
        let others = record.speakerNames.keys.filter { record.canonicalSpeaker($0) == $0 && $0 != canonical }.sorted()
        return Menu {
            if canonical != id { Button("恢复独立发言人标签") { state.unmergeSpeaker(id) } }
            Button("修改名称…") { renaming = canonical; name = record.speakerName(canonical) }
            if !others.isEmpty {
                Menu("合并到") { ForEach(others, id: \.self) { target in Button(record.speakerName(target)) { state.mergeSpeaker(canonical, into: target) } } }
            }
        } label: { Text(record.speakerName(canonical)).font(AppTypography.body.weight(.medium)).lineLimit(1).truncationMode(.tail).frame(minHeight: 28) }
            .menuStyle(.borderlessButton).fixedSize().help("修改名称或合并同一人的发言")
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

private struct TranscriptParagraphEditor: View {
    let cancel: () -> Void
    let save: (String) -> Void
    @State private var draft: String
    init(paragraph: TranscriptParagraph, cancel: @escaping () -> Void, save: @escaping (String) -> Void) {
        self.cancel = cancel; self.save = save
        _draft = State(initialValue: paragraph.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑这段文字").font(AppTypography.heading)
            Text("保留这段录音的时间和发言人标签。").font(AppTypography.secondary).foregroundStyle(.secondary)
            TextEditor(text: $draft).font(AppTypography.transcript).lineSpacing(6)
            HStack { Button("取消", action: cancel); Spacer(); Button("保存") { save(draft) }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 620, height: 360)
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
