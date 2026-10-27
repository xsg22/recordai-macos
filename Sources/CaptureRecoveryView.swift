import SwiftUI

struct CaptureRecoveryView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("恢复录音").font(.system(size: 24, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.disabled(state.recoveryBusy).keyboardShortcut(.cancelAction)
            }
            Text("检查中断前的原轨，将可读取的音频保存到当前录音。原文、原轨和已保存片段都会保留。")
                .foregroundStyle(.secondary)
            HStack {
                if state.recoveryBusy { ProgressView().controlSize(.small) }
                Text(state.recoveryStatus).font(AppTypography.body).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(state.recoveryCandidates) { candidate in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("录音片段 · \(candidate.id.uuidString.prefix(8))").font(AppTypography.heading)
                            Text("可恢复约 \(Int(candidate.duration)) 秒 · \(candidate.existingMix != nil ? "已有完整混音" : "原始音轨合成")")
                                .font(AppTypography.secondary).foregroundStyle(.secondary)
                            ForEach(candidate.warnings, id: \.self) { Text($0).font(AppTypography.secondary).foregroundStyle(.orange) }
                            Button(candidate.warnings.isEmpty ? "恢复并保存此片段" : "仅恢复可读取的音轨") { state.recoverCapture(candidate) }
                                .disabled(state.locked)
                            Divider()
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
        }.padding(26).frame(width: 720, height: 620).font(AppTypography.body).controlSize(.large)
            .task { state.findRecoverableAudio() }
    }
}
