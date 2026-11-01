import SwiftUI

/// Handwritten notes remain independent from every generated artifact.
struct MeetingWorkspaceView: View {
    @ObservedObject var state: AppState
    @State private var tab = "我的笔记"
    private let close: (() -> Void)?
    @State private var question = ""
    @State private var showingNoteSources = false
    private let accent = RecordAITheme.accent
    init(state: AppState, initialTab: String = "我的笔记", close: (() -> Void)? = nil) {
        self.state = state; self.close = close; _tab = State(initialValue: initialTab)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RecordAIPageHeader(title: tab == "我的笔记" ? "笔记与本地助手" : "会议助手", subtitle: state.current?.title ?? "") { if let close { Button("完成", action: close).keyboardShortcut(.cancelAction) } }
            HStack(spacing: 4) {
                ForEach(["我的笔记", "摘要", "对话", "Live Q&A"], id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item).font(AppTypography.secondary.weight(tab == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(tab == item ? RecordAITheme.accent : .secondary)
                            .background(tab == item ? RecordAITheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }.padding(4).background(RecordAITheme.tabs, in: RoundedRectangle(cornerRadius: 10))
            if tab == "我的笔记" { notesPanel.frame(maxHeight: .infinity) }
            else { assistantPanel.frame(maxHeight: .infinity) }
            if state.recording || state.preparing || (state.busy && !state.liveText.isEmpty) {
                DisclosureGroup("实时来源 · 未定稿") { livePanel.frame(height: 130) }
            }
        }
        .frame(height: tab == "我的笔记" ? 513 : 432)
        .buttonStyle(RecordAISecondaryButtonStyle())
        .onAppear { state.refreshAssistantAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in state.refreshAssistantAvailability() }
        .onChange(of: state.selection) { question = "" }
    }

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("随手记录想法，原稿始终保留。Gemma 结果单独保存。").font(AppTypography.secondary).foregroundStyle(.secondary)
            TextEditor(text: $state.notes).font(AppTypography.body).lineSpacing(6)
                .scrollContentBackground(.hidden).onChange(of: state.notes) { state.scheduleSave() }
                .padding(12).background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RecordAITheme.border, lineWidth: 1))
            if !state.enhancedNotes.isEmpty {
                DisclosureGroup("AI 增强笔记 · 请核对") {
                    ScrollView { Text(state.enhancedNotes).font(AppTypography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    if state.current?.enhancedNotesContextWasTruncated == true { Text("仅基于选取片段，未覆盖整场。").font(AppTypography.secondary).foregroundStyle(.orange) }
                    citationView(state.current?.enhancedNotesCitations ?? [])
                }
            }
            HStack {
                Button("查看来源") { showingNoteSources = true }.disabled(state.text.isEmpty && state.liveText.isEmpty)
                    .popover(isPresented: $showingNoteSources) {
                        VStack(alignment: .leading, spacing: 16) {
                            RecordAIPageHeader(title: "会议来源", subtitle: state.text.isEmpty ? "实时文字 · 未定稿" : "转录正文") { Button("完成") { showingNoteSources = false } }
                            ScrollView { Text(state.text.isEmpty ? state.liveText : state.text).font(AppTypography.body).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }.padding(24).frame(width: 520, height: 360)
                    }
                Spacer()
                Button("增强笔记") { state.enhanceMeetingNotes() }.buttonStyle(RecordAIPrimaryButtonStyle()).disabled(!state.assistantModelAvailable || state.assistantBusy || (state.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.padding(.top, 12)
        }.background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var assistantPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !state.assistantModelAvailable && tab != "转写" {
                HStack {
                    Text("下载并启用 Gemma 后，可离线整理笔记和问答。").font(AppTypography.secondary).foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink { Text("模型设置") }
                }
            }
            if tab == "转写" { transcriptPanel }
            else if tab == "摘要" { summaryPanel }
            else { conversationPanel(live: tab == "Live Q&A") }
            if state.assistantBusy {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(state.assistantOperation + " · " + state.assistantStatus).font(AppTypography.secondary).lineLimit(2)
                        Spacer()
                        Button("取消") { state.cancelAssistant() }
                    }
                    if !state.assistantDraft.isEmpty {
                        ScrollView { Text(state.assistantDraft).font(AppTypography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 80)
                    }
                }
            } else if !state.assistantStatus.isEmpty {
                Text(state.assistantStatus).font(AppTypography.secondary).foregroundStyle(.secondary)
            }
        }.background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("会议摘要").font(AppTypography.body.weight(.semibold))
                Spacer()
                Button(state.summary.isEmpty ? "生成摘要" : "重新生成") { state.generateSummary() }
                    .disabled(!state.assistantModelAvailable || state.assistantBusy || state.text.isEmpty)
            }
            Text("依据最终转录生成；内容可编辑并保存，请核对决定和待办。").font(AppTypography.secondary).foregroundStyle(.secondary)
            TextEditor(text: $state.summary).font(AppTypography.body).lineSpacing(6).scrollContentBackground(.hidden)
                .onChange(of: state.summary) { state.scheduleSave() }
            if state.current?.summaryContextWasTruncated == true { Text("仅基于选取片段，未覆盖整场。").font(AppTypography.secondary).foregroundStyle(.orange) }
            citationView(state.current?.summaryCitations ?? [])
        }
    }

    private func conversationPanel(live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if live {
                Toggle("自动发现讨论中的问题", isOn: $state.liveQAEnabled).toggleStyle(.checkbox)
                    .disabled(!state.recording || !state.assistantModelAvailable)
                    .font(AppTypography.secondary)
                    .help("每隔至少 15 秒检查新增实时片段，停止录音即关闭；不自动同步。")
                HStack {
                    Text("依据实时文字 · 未定稿").font(AppTypography.secondary).foregroundStyle(.orange)
                    Spacer()
                    Button("识别讨论中的问题") { state.findLiveQuestions() }
                        .disabled(!state.assistantModelAvailable || state.assistantBusy || state.liveText.isEmpty)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let entries = (state.current?.assistantEntries ?? []).filter { $0.isLive == live }
                    if entries.isEmpty {
                        Text(live ? "实时文字出现后，可以问当前讨论、识别待回答的问题。回答可能随定稿修订。" : (state.text.isEmpty && !state.liveText.isEmpty ? "当前依据实时文字回答，结果未定稿；最终转录完成后可再次核对。" : "问这场会议的结论、分歧或待办。助手依据会议来源回答，不发送到云端。"))
                            .font(AppTypography.body).foregroundStyle(.secondary).padding(.vertical, 15)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(entry.question).font(AppTypography.body.weight(.semibold))
                            Text(entry.answer).font(AppTypography.body).lineSpacing(5).textSelection(.enabled)
                            Text(entry.created, format: .dateTime.hour().minute()).font(AppTypography.secondary).foregroundStyle(.secondary)
                            citationView(entry.citations)
                            if entry.contextWasTruncated { Text("仅基于选取片段，未覆盖整场。").font(AppTypography.secondary).foregroundStyle(.secondary) }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(RecordAITheme.quiet, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            RecordAIInfo(text: "依据会议文字回答。实时 Q&A 的结果属于草稿，需在定稿后核对。")
            HStack {
                TextField(live || (state.text.isEmpty && !state.liveText.isEmpty) ? "问当前讨论（未定稿）…" : "问这场会议…", text: $question).textFieldStyle(.roundedBorder)
                    .onSubmit { sendQuestion(live: live) }
                Button("提问") { sendQuestion(live: live) }.buttonStyle(RecordAIPrimaryButtonStyle())
                    .disabled(!state.assistantModelAvailable || state.assistantBusy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (live ? state.liveText.isEmpty : (state.text.isEmpty && state.liveText.isEmpty)))
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcriptPanel: some View { TranscriptTimelineView(state: state) }

    private var livePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(state.recording ? "实时转写" : "录音时实时结果", systemImage: "waveform")
                Spacer()
                Text("未定稿 · 不用于同步").foregroundStyle(.orange)
            }.font(AppTypography.secondary)
            if !state.liveStatus.isEmpty {
                Text(state.liveStatus).font(AppTypography.secondary)
                    .foregroundStyle(state.liveStatus.contains("异常") || state.liveStatus.contains("失败") || state.liveStatus.contains("缺失") ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.liveText.isEmpty ? (state.liveStatus.isEmpty ? "等待语音，识别结果会持续出现…" : state.liveStatus) : state.liveText)
                        .font(AppTypography.transcript).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("live-tail")
                }.onChange(of: state.liveText) { proxy.scrollTo("live-tail", anchor: .bottom) }
            }
        }.padding(12).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func citationView(_ citations: [MeetingCitation]) -> some View {
        Group {
            if !citations.isEmpty {
                DisclosureGroup("查看引用来源（\(citations.count)）") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(citations) { citation in
                            Text("[\(citation.id)] \(citation.kind == "transcript" ? "转录" : "手工笔记")\n\(citation.text)")
                                .font(AppTypography.secondary).textSelection(.enabled)
                        }
                    }
                }.font(AppTypography.secondary)
            }
        }
    }
    private func sendQuestion(live: Bool) {
        guard state.assistantModelAvailable, !state.assistantBusy, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.askAssistant(question, live: live); question = ""
    }
}
