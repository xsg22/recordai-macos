import SwiftUI

struct CaptureRecoveryView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RecordAIPageHeader(title: L10n.text("恢复录音"), subtitle: L10n.text("检查中断前的原轨，恢复可读取的片段。")) {
                Button(L10n.text("完成")) { dismiss() }.disabled(state.recoveryBusy).keyboardShortcut(.cancelAction)
            }
            RecordAIInfo(text: L10n.text("原文、原轨和已保存片段都会保留；恢复不会覆盖已有录音。"))
            if state.recoveryBusy || (!state.recoveryStatus.hasPrefix("找到") && !state.recoveryStatus.hasPrefix("没有尚未")) {
            HStack {
                if state.recoveryBusy { ProgressView().controlSize(.small) }
                Text(L10n.text(state.recoveryStatus)).font(AppTypography.body).fixedSize(horizontal: false, vertical: true)
            }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !state.recoveryBusy && state.recoveryCandidates.isEmpty && !state.recoveryStatus.isEmpty {
                        VStack(spacing: 14) {
                            Text(L10n.text("没有未登记的片段")).font(.system(size: 23, weight: .semibold))
                            Text(L10n.text("已有音频可直接回放或继续转录。")).font(AppTypography.secondary).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                    ForEach(Array(state.recoveryCandidates.enumerated()), id: \.element.id) { index, candidate in
                        RecordAICard {
                            Text(String(format: L10n.text("录音片段 · %02d"), index + 1)).font(AppTypography.heading)
                            Text(L10n.text("可恢复约 \(durationText(candidate.duration)) · \(candidate.canonical ? "原始 AAC 片段" : candidate.existingMix != nil ? "已有完整混音" : "原始音轨合成")"))
                                .font(AppTypography.secondary).foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                            ForEach(Array(candidate.tracks.enumerated()), id: \.offset) { trackIndex, track in
                                if trackIndex > 0 { Divider() }
                                HStack {
                                    Text(L10n.text(track.kind == .microphone ? "麦克风原轨" : "系统声音原轨"))
                                    Spacer()
                                    Text(L10n.text("可读取")).font(AppTypography.secondary).foregroundStyle(.green)
                                }.padding(.vertical, 11)
                            }
                            }
                            ForEach(candidate.warnings, id: \.self) { Text(L10n.text($0)).font(AppTypography.secondary).foregroundStyle(.orange) }
                            Button(L10n.text("恢复并继续录音")) {
                                state.recoverCapture(candidate, continueAfterSaving: true)
                                dismiss()
                            }.disabled(state.locked)
                            Button(L10n.text(candidate.warnings.isEmpty ? "恢复并保存此片段" : "仅恢复可读取的音轨")) { state.recoverCapture(candidate) }
                                .buttonStyle(RecordAIPrimaryButtonStyle()).disabled(state.locked)
                        }
                    }
                    ForEach(state.recoveryWarnings, id: \.self) { Text(L10n.text($0)).font(AppTypography.secondary).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(L10n.text("重新检查")) { state.findRecoverableAudio() }.disabled(state.locked)
                Spacer()
                if state.recoveryBusy { Button(L10n.text("取消当前操作")) { state.cancelRecovery() } }
                else { Button(L10n.text("打开原轨文件夹")) { state.revealStorage() } }
            }
        }.padding(28).frame(width: 720, height: !state.recoveryBusy && state.recoveryCandidates.isEmpty ? 418 : 524).font(AppTypography.body)
            .buttonStyle(RecordAISecondaryButtonStyle()).tint(RecordAITheme.accent)
            .task { state.findRecoverableAudio() }
    }

    private func durationText(_ duration: Double) -> String {
        let seconds = Int(duration.isFinite ? max(0, min(duration, Double(Int.max / 2))) : 0)
        return L10n.text(seconds >= 60 ? "\(seconds / 60) 分 \(seconds % 60) 秒" : "\(seconds) 秒")
    }
}
