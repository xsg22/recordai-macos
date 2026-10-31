import SwiftUI

/// Handwritten notes remain independent from every generated artifact.
struct MeetingWorkspaceView: View {
    @ObservedObject var state: AppState
    @State private var tab = "转写"
    @State private var question = ""
    @State private var showLiveHistory = false
    @State private var narrowPane = "助手"
    @State private var transcriptNotesRatio: CGFloat = 0.32
    @State private var notesRatio: CGFloat = 0.65
    @State private var dividerDragStart: CGFloat?
    private let accent = Color(red: 0.08, green: 0.35, blue: 0.95)
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                if geometry.size.width >= 760 {
                    let usableWidth = geometry.size.width - 8
                    let notesWidth = min(max(350, usableWidth * (tab == "转写" ? transcriptNotesRatio : notesRatio)), usableWidth - 330)
                    HStack(spacing: 0) {
                        notesPanel.frame(width: notesWidth).frame(maxHeight: .infinity)
                        Rectangle().fill(Color(nsColor: .separatorColor))
                            .frame(width: 1).frame(maxHeight: .infinity)
                            .frame(width: 8).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if dividerDragStart == nil { dividerDragStart = notesWidth }
                                    let width = min(max(350, (dividerDragStart ?? notesWidth) + value.translation.width), usableWidth - 330)
                                    if tab == "转写" { transcriptNotesRatio = width / usableWidth }
                                    else { notesRatio = width / usableWidth }
                                }
                                .onEnded { _ in dividerDragStart = nil })
                            .accessibilityLabel("调整笔记与助手宽度")
                        assistantPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Picker("工作区", selection: $narrowPane) {
                        Text("我的笔记").tag("笔记"); Text("会议助手").tag("助手")
                    }.pickerStyle(.segmented)
                    if narrowPane == "笔记" { notesPanel.frame(maxHeight: .infinity) }
                    else { assistantPanel.frame(maxHeight: .infinity) }
                }
                if (tab != "转写" || (geometry.size.width < 760 && narrowPane == "笔记")) && (state.recording || state.preparing || (state.busy && !state.liveText.isEmpty)) {
                    livePanel.frame(height: min(120, max(88, geometry.size.height * 0.18)))
                }
            }
        }
        .onAppear { state.refreshAssistantAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in state.refreshAssistantAvailability() }
        .onChange(of: state.selection) { question = "" }
        .onChange(of: state.recording) { if state.recording { tab = "转写"; narrowPane = "助手" } }
        .onChange(of: state.busy) { if state.busy { tab = "转写"; narrowPane = "助手" } }
    }

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("我的笔记", systemImage: "square.and.pencil").font(AppTypography.heading)
                Spacer()
                Button("增强笔记") { state.enhanceMeetingNotes() }.disabled(!state.assistantModelAvailable || state.assistantBusy || (state.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            Text("随手记录想法，原稿始终保留。Gemma 结果单独保存。").font(AppTypography.secondary).foregroundStyle(.secondary)
            TextEditor(text: $state.notes).font(AppTypography.body).lineSpacing(6)
                .scrollContentBackground(.hidden).onChange(of: state.notes) { state.scheduleSave() }
            if !state.enhancedNotes.isEmpty {
                DisclosureGroup("AI 增强笔记 · 请核对") {
                    ScrollView { Text(state.enhancedNotes).font(AppTypography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    if state.current?.enhancedNotesContextWasTruncated == true { Text("仅基于选取片段，未覆盖整场。").font(AppTypography.secondary).foregroundStyle(.orange) }
                    citationView(state.current?.enhancedNotesCitations ?? [])
                }
            }
        }.padding(14).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var assistantPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tab == "转写" ? "会议转写" : "本地会议助手", systemImage: tab == "转写" ? "waveform" : "sparkles").font(AppTypography.heading)
                Spacer()
                if tab != "转写" { Text("Gemma").font(AppTypography.secondary).foregroundStyle(accent) }
            }
            Picker("助手", selection: $tab) {
                Text("对话").tag("对话")
                Text("Live Q&A").tag("Live Q&A")
                Text("摘要").tag("摘要")
                Text("转写").tag("转写")
            }.pickerStyle(.segmented).labelsHidden().controlSize(.regular)
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
        }.padding(14).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
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
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack {
                TextField(live || (state.text.isEmpty && !state.liveText.isEmpty) ? "问当前讨论（未定稿）…" : "问这场会议…", text: $question).textFieldStyle(.roundedBorder)
                    .onSubmit { sendQuestion(live: live) }
                Button("提问") { sendQuestion(live: live) }
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
