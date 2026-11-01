import SwiftUI

struct CaptureRecoveryView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RecordAIPageHeader(title: "恢复录音", subtitle: "检查中断前的原轨，恢复可读取的片段。") {
                Button("完成") { dismiss() }.disabled(state.recoveryBusy).keyboardShortcut(.cancelAction)
            }
            RecordAIInfo(text: "原文、原轨和已保存片段都会保留；恢复不会覆盖已有录音。")
            if state.recoveryBusy || (!state.recoveryStatus.hasPrefix("找到") && !state.recoveryStatus.hasPrefix("没有尚未")) {
            HStack {
                if state.recoveryBusy { ProgressView().controlSize(.small) }
                Text(state.recoveryStatus).font(AppTypography.body).fixedSize(horizontal: false, vertical: true)
            }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !state.recoveryBusy && state.recoveryCandidates.isEmpty && !state.recoveryStatus.isEmpty {
                        VStack(spacing: 14) {
                            Text("没有未登记的片段").font(.system(size: 23, weight: .semibold))
                            Text("已有音频可直接回放或继续转录。").font(AppTypography.secondary).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                    ForEach(state.recoveryCandidates) { candidate in
                        RecordAICard {
                            Text("录音片段 · \(candidate.id.uuidString.prefix(8))").font(AppTypography.heading)
                            Text("可恢复约 \(Int(candidate.duration)) 秒 · \(candidate.existingMix != nil ? "已有完整混音" : "原始音轨合成")")
                                .font(AppTypography.secondary).foregroundStyle(.secondary)
                            ForEach(Array(candidate.tracks.enumerated()), id: \.offset) { _, track in
                                HStack {
                                    Text(track.kind == .microphone ? "麦克风原轨" : "系统声音原轨")
                                    Spacer()
                                    Text("可读取").font(AppTypography.secondary).foregroundStyle(.green)
                                }.padding(.vertical, 7)
                                Divider()
                            }
                            ForEach(candidate.warnings, id: \.self) { Text($0).font(AppTypography.secondary).foregroundStyle(.orange) }
                            Button(candidate.warnings.isEmpty ? "恢复并保存此片段" : "仅恢复可读取的音轨") { state.recoverCapture(candidate) }
                                .buttonStyle(RecordAIPrimaryButtonStyle()).disabled(state.locked)
                        }
                    }
                    ForEach(state.recoveryWarnings, id: \.self) { Text($0).font(AppTypography.secondary).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("重新检查") { state.findRecoverableAudio() }.disabled(state.locked)
                Spacer()
                if state.recoveryBusy { Button("取消当前操作") { state.cancelRecovery() } }
                else { Button("打开原轨文件夹") { state.revealStorage() } }
            }
        }.padding(28).frame(width: 720, height: !state.recoveryBusy && state.recoveryCandidates.isEmpty ? 418 : 524).font(AppTypography.body)
            .buttonStyle(RecordAISecondaryButtonStyle()).tint(RecordAITheme.accent)
            .task { state.findRecoverableAudio() }
    }
}
