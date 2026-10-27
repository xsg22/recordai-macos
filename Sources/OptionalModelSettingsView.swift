import AppKit
import SwiftUI

struct OptionalModelSettingsView: View {
    @StateObject private var store = OptionalModelStore()
    @State private var deleting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("本地模型").font(.largeTitle.bold())
                Text("实时转写由 Paraformer 完成，停止录音后由 Qwen3-ASR 生成定稿；Gemma 整理摘要、笔记和问答。全部在本机运行。")
                    .foregroundStyle(.secondary)
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Paraformer · 中英双语实时转写", systemImage: "waveform")
                            Label("Qwen3-ASR 1.7B · 会后定稿", systemImage: "text.bubble")
                            Label("Silero VAD · 语音检测", systemImage: "waveform.badge.mic")
                            Label("Sortformer · 发言人区分（最多4位）", systemImage: "person.2")
                            Label("Qwen 对齐 · 将文字对应到发言时间", systemImage: "text.alignleft")
                        }
                        Spacer()
                        Text(ASRResources.qwen != nil && ASRResources.paraformer != nil ? "已下载" : "请下载语音模型").foregroundStyle(.secondary)
                    }.padding(10)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("Gemma · 本地会议助手", systemImage: "cpu")
                            Spacer()
                            Text(store.activeID == nil ? "未启用" : "已选择本地权重").foregroundStyle(.secondary)
                        }
                        Picker("模型", selection: $store.selectedID) {
                            ForEach(OptionalModelSpec.all) { model in Text(model.name).tag(model.id) }
                        }.disabled(store.busy)
                        Text(store.selected.estimatedDownload).font(.callout)
                        Text("建议至少 \(store.selected.recommendedMemoryGB) GB 内存；本机 \(store.availableMemoryGB) GB。下载内容包含文本权重和图片编码器。")
                            .font(.caption).foregroundStyle(.secondary)
                        if store.availableMemoryGB < store.selected.recommendedMemoryGB {
                            Label("此模型可能占用较多内存，优先选择较小版本。", systemImage: "memorychip").font(.caption).foregroundStyle(.orange)
                        }
                        if store.installed.contains(store.selectedID) {
                            HStack {
                                Button("使用这个模型") { store.chooseInstalled(store.selectedID) }.disabled(store.busy)
                                Button("移除下载…", role: .destructive) { deleting = true }.disabled(store.busy)
                            }
                        } else {
                            HStack {
                                Link("Gemma 使用条款", destination: URL(string: "https://ai.google.dev/gemma/terms")!)
                                Link("模型来源", destination: URL(string: "https://huggingface.co/" + store.selected.repository)!)
                            }.font(.caption)
                            Toggle("我已阅读并同意 Gemma 使用条款", isOn: $store.licenseAccepted).disabled(store.busy)
                            Button("选择并下载") { store.downloadSelected() }
                                .buttonStyle(.borderedProminent).disabled(store.busy || !store.licenseAccepted)
                        }
                        if store.busy {
                            ProgressView(value: store.progress)
                            if store.totalBytes > 0 {
                                Text("\(format(store.completedBytes)) / \(format(store.totalBytes))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if store.downloading { Button("取消下载") { store.cancel() } }
                        }
                        Text(store.status).font(.callout).foregroundStyle(.secondary)
                        Divider()
                        Text("启用后可在会议工作台生成摘要、增强笔记和问答。当前助手处理会议文字；图片理解尚未提供。AI 内容需要核对，原始转录和笔记会保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                HStack {
                    Button("关闭辅助模型") { store.disable() }.disabled(store.busy || store.activeID == nil)
                    Button("打开模型文件夹") { store.revealFiles() }
                }
            }.padding(28)
        }.frame(minWidth: 640, minHeight: 650)
            .task { await store.refreshInstalled() }
            .confirmationDialog("移除已下载的模型？", isPresented: $deleting) {
                Button("移到废纸篓", role: .destructive) { store.removeSelected() }
                Button("取消", role: .cancel) { }
            } message: { Text("之后使用需要重新下载，不影响会议和录音。") }
            .alert("模型下载", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("好的") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
    private func format(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
