import SwiftUI

/// Only rearranges text already present in the saved summary; it never invents points.
struct MeetingSummaryOutline {
    let body: String
    let points: [String]
    init(_ summary: String) {
        var inPoints = false
        var remaining: [String] = []
        var extracted: [String] = []
        for line in summary.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = clean.trimmingCharacters(in: CharacterSet(charactersIn: "#*：: "))
            if ["讨论要点", "关键要点"].contains(heading) { inPoints = true; continue }
            if clean.hasPrefix("#") { inPoints = false }
            if inPoints, clean.hasPrefix("- ") || clean.hasPrefix("• ") || clean.hasPrefix("* ") {
                extracted.append(String(clean.dropFirst(2))); continue
            }
            remaining.append(line)
        }
        body = extracted.isEmpty ? summary : remaining.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        points = extracted
    }
}

struct MeetingInspector: View {
    @ObservedObject var state: AppState
    @State private var tab = "会议总结"
    @State private var editing = false
    @State private var editingID: UUID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                Label("本地存储 · 隐私安全", systemImage: "lock.shield").font(AppTypography.secondary.weight(.semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 12).padding(.vertical, 9).background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 4) {
                    inspectorTab("会议总结", symbol: "doc.text")
                    inspectorTab("行动项", symbol: "checkmark.square")
                }.padding(4).background(RecordAITheme.tabs, in: RoundedRectangle(cornerRadius: 10))
                }
                if tab == "会议总结" {
                    summary
                    Divider()
                }
                MeetingActionList(state: state)
                Divider()
                MeetingAttachmentsView(state: state)
            }.font(AppTypography.secondary).padding(.leading, 24).padding(.vertical, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .leading) { Rectangle().fill(RecordAITheme.border).frame(width: 1) }
            .onAppear { state.refreshAssistantAvailability() }
            .onChange(of: state.selection) { tab = "会议总结"; editing = false }
            .sheet(isPresented: $editing) {
                MeetingSummaryEditor(summary: state.summary, cancel: { editing = false }) { value in
                    guard let editingID else { return false }
                    let success = state.updateSummary(value, meetingID: editingID)
                    if success { editing = false }
                    return success
                }
            }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("会议摘要", systemImage: "text.alignleft").font(.system(size: 17, weight: .semibold))
                Spacer()
                Menu {
                    Button("编辑摘要") { editingID = state.current?.id; editing = true }.disabled(state.locked || state.assistantBusy)
                    Button(state.summary.isEmpty ? "生成摘要" : "重新生成摘要") { state.generateSummary() }
                        .disabled(!state.assistantModelAvailable || state.assistantBusy || state.text.isEmpty || state.recording || state.busy)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("摘要操作")
            }
            if state.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(state.assistantModelAvailable ? "转录完成后可生成摘要，也可以手动记录。" : "启用本地助手模型后可生成摘要，也可以手动记录。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(state.assistantModelAvailable ? "生成摘要" : "编辑摘要") {
                    if state.assistantModelAvailable { state.generateSummary() }
                    else { editingID = state.current?.id; editing = true }
                }.disabled(state.locked || state.assistantBusy)
            } else {
                let outline = MeetingSummaryOutline(state.summary)
                if !outline.body.isEmpty { Text(outline.body).font(.system(size: 14)).lineSpacing(10).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if !outline.points.isEmpty {
                    Divider()
                    Label("关键要点", systemImage: "sparkle").font(AppTypography.heading)
                    ForEach(Array(outline.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 8) { Text("•"); Text(point).lineSpacing(5).textSelection(.enabled) }
                    }
                }
                Text("请核对摘要与录音。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if state.assistantBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(state.assistantOperation + " · " + state.assistantStatus).lineLimit(3)
                    Spacer()
                    Button("取消") { state.cancelAssistant() }
                }
            }
            if state.current?.summaryContextWasTruncated == true { RecordAIInfo(text: "摘要仅基于选取片段，未覆盖整场会议。", warning: true) }
            if !(state.current?.summaryCitations.isEmpty ?? true) {
                DisclosureGroup("查看摘要引用") {
                    ForEach(state.current?.summaryCitations ?? []) { citation in Text(citation.text).font(AppTypography.secondary).textSelection(.enabled) }
                }
            }
        }
    }

    private func inspectorTab(_ title: String, symbol: String) -> some View {
        Button { tab = title } label: {
            Label(title, systemImage: symbol).font(AppTypography.secondary.weight(tab == title ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .foregroundStyle(tab == title ? RecordAITheme.accent : .secondary)
                .background(tab == title ? RecordAITheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(tab == title ? .isSelected : [])
    }
}

struct MeetingSummaryEditor: View {
    let cancel: () -> Void
    let save: (String) -> Bool
    @State private var draft: String
    @State private var failed = false
    init(summary: String, cancel: @escaping () -> Void, save: @escaping (String) -> Bool) {
        self.cancel = cancel; self.save = save; _draft = State(initialValue: summary)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RecordAIPageHeader(title: "编辑会议摘要", subtitle: "修改只影响摘要，原始转录会保留。") { Button("取消", action: cancel).keyboardShortcut(.cancelAction) }
            TextEditor(text: $draft).font(AppTypography.body).lineSpacing(6).padding(12)
                .scrollContentBackground(.hidden).background(RecordAITheme.tabs, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("会议摘要正文")
            if failed { RecordAIInfo(text: "摘要尚未保存，输入仍保留，请重试。", warning: true) }
            HStack { Spacer(); Button("保存") { failed = !save(draft) }.buttonStyle(RecordAIPrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 720, height: 450).buttonStyle(RecordAISecondaryButtonStyle())
    }
}
