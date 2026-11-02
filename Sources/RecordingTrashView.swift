import SwiftUI

struct RecordingTrashView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    let restored: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("回收站")).font(.system(size: 26, weight: .semibold))
                Text(L10n.text("恢复后，录音、文字和附件会一同回到录音库。"))
                    .font(AppTypography.secondary).foregroundStyle(RecordAITheme.muted)
            }.padding(.bottom, 8)
            if state.trashedHistory.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "trash").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(L10n.text("回收站为空")).font(.system(size: 21, weight: .semibold))
                    Text(L10n.text("移入回收站的录音会显示在这里。")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 32) {
                        ForEach(state.trashedHistory) { record in
                            RecordAICard {
                                HStack(spacing: 20) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        Text(record.title).font(.system(size: 14, weight: .semibold))
                                        (Text(record.created, format: .dateTime.month().day()) + Text(" · " + recordingDurationText(record.duration)))
                                            .font(AppTypography.secondary).foregroundStyle(RecordAITheme.ink)
                                    }.padding(.top, 12).frame(height: 92, alignment: .topLeading)
                                    Spacer()
                                    Button(L10n.text("恢复录音")) { if state.restoreTrash(record.id) { restored() } }
                                        .buttonStyle(RecordAIPrimaryButtonStyle()).disabled(state.locked)
                                }.frame(minHeight: 92)
                            }
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ConfirmTrashView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    let record: MeetingRecord
    @State private var issue = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "trash").font(.system(size: 28)).foregroundStyle(.orange)
                .frame(width: 64, height: 64).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
            Text(L10n.text("移到回收站？")).font(.system(size: 24, weight: .semibold))
            Text(L10n.text("会议文本、托管音频和附件一起移入回收站，可以恢复；导入前的源文件保留。"))
                .font(AppTypography.secondary).foregroundStyle(.secondary).lineSpacing(7).fixedSize(horizontal: false, vertical: true)
            if issue { RecordAIInfo(text: L10n.text("操作尚未完成，请检查错误提示后重试。"), warning: true) }
            HStack {
                Button(L10n.text("取消")) { state.deletionRequest = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("移到回收站")) { issue = !state.confirmTrash(record.id) }
                    .buttonStyle(RecordAIPrimaryButtonStyle()).disabled(state.locked)
            }
        }.padding(28).frame(width: 470).buttonStyle(RecordAISecondaryButtonStyle())
    }
}
