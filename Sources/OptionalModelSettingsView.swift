import AppKit
import SwiftUI

struct OptionalModelSettingsView: View {
    @StateObject private var store: OptionalModelStore
    @State private var deleting = false
    @State private var showingDetails = false
    @MainActor init(store: OptionalModelStore? = nil) { _store = StateObject(wrappedValue: store ?? OptionalModelStore()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            RecordAICard(spacing: 12) {
                Text("本地会议助手").font(AppTypography.heading)
                RecordAISettingRow(title: "模型") {
                    RecordAIChoicePicker(title: "模型", items: OptionalModelSpec.all.map { ($0.name.components(separatedBy: " · ").first ?? $0.name, $0.id) }, selection: $store.selectedID).disabled(store.busy)
                }
                Text("整理摘要、增强笔记和问答。\(store.selected.estimatedDownload)；建议 \(store.selected.recommendedMemoryGB) GB 内存，本机 \(store.availableMemoryGB) GB。原稿始终保留。")
                    .font(AppTypography.secondary).lineSpacing(6).foregroundStyle(store.availableMemoryGB < store.selected.recommendedMemoryGB ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !store.installed.contains(store.selectedID) {
                    HStack {
                        Toggle("我已阅读并同意 Gemma 使用条款", isOn: $store.licenseAccepted).disabled(store.busy)
                        Link("查看条款 ↗", destination: URL(string: "https://ai.google.dev/gemma/terms")!).buttonStyle(.plain).foregroundStyle(RecordAITheme.accent)
                    }.font(AppTypography.secondary)
                }
                HStack {
                    if store.installed.contains(store.selectedID) {
                        Button("使用这个模型") { store.chooseInstalled(store.selectedID) }.buttonStyle(RecordAIPrimaryButtonStyle()).disabled(store.busy)
                    } else {
                        Button("选择并下载") { store.downloadSelected() }.buttonStyle(RecordAIPrimaryButtonStyle()).disabled(store.busy || !store.licenseAccepted)
                    }
                    Button("关闭辅助模型") { store.disable() }.disabled(store.busy || store.activeID == nil)
                    Spacer()
                    Button("管理…") { showingDetails = true }.buttonStyle(.plain).foregroundStyle(RecordAITheme.accent)
                        .accessibilityLabel("模型来源与管理")
                        .popover(isPresented: $showingDetails) { modelDetails }
                }
                if store.busy {
                    ProgressView(value: store.progress)
                    Text(store.status).font(AppTypography.secondary).foregroundStyle(.secondary)
                    if store.totalBytes > 0 { Text("\(format(store.completedBytes)) / \(format(store.totalBytes))").font(AppTypography.secondary).monospacedDigit() }
                    if store.downloading { Button("取消下载") { store.cancel() } }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task { await store.refreshInstalled() }
            .confirmationDialog("移除已下载的模型？", isPresented: $deleting) {
                Button("移到废纸篓", role: .destructive) { store.removeSelected() }
                Button("取消", role: .cancel) { }
            } message: { Text("之后使用需要重新下载，不影响会议和录音。") }
            .alert("模型下载", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("好的") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
    private var modelDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            RecordAIPageHeader(title: "模型来源与管理", subtitle: store.selected.name) { Button("完成") { showingDetails = false } }
            Link("模型来源 ↗", destination: URL(string: "https://huggingface.co/" + store.selected.repository)!)
            Text("下载包含文本权重和图片编码器；当前助手只处理会议文字。AI 内容需要核对。")
                .font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("打开模型文件夹") { store.revealFiles() }
                if store.installed.contains(store.selectedID) { Button("移除下载…", role: .destructive) { showingDetails = false; deleting = true }.disabled(store.busy) }
            }
        }.padding(24).frame(width: 520).buttonStyle(RecordAISecondaryButtonStyle())
    }
    private func format(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
