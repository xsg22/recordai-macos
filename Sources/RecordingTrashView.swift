import SwiftUI

struct RecordingTrashView: View {
    @ObservedObject var state: AppState
    let restored: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 44) {
            RecordAIPageHeader(title: "回收站", subtitle: "恢复后，录音、文字和附件会一同回到录音库。") { EmptyView() }
            if state.trashedHistory.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "trash").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("回收站为空").font(.system(size: 21, weight: .semibold))
                    Text("移入回收站的录音会显示在这里。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 32) {
                        ForEach(state.trashedHistory) { record in
                            RecordAICard {
                                HStack(spacing: 20) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(record.title).font(AppTypography.heading)
                                                                    Text(record.created, format: .dateTime.year().month().day().hour().minute())
                                            .font(AppTypography.secondary).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("恢复录音") { if state.restoreTrash(record.id) { restored() } }
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
    @ObservedObject var state: AppState
    let record: MeetingRecord
    @State private var issue = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "trash").font(.system(size: 28)).foregroundStyle(.orange)
                .frame(width: 64, height: 64).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
            Text("移到回收站？").font(.system(size: 24, weight: .semibold))
            Text("会议文本、托管音频和附件一起移入回收站，可以恢复；导入前的源文件保留。")
                .font(AppTypography.secondary).foregroundStyle(.secondary).lineSpacing(7).fixedSize(horizontal: false, vertical: true)
            if issue { RecordAIInfo(text: "操作尚未完成，请检查错误提示后重试。", warning: true) }
            HStack {
                Button("取消") { state.deletionRequest = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("移到回收站") { issue = !state.confirmTrash(record.id) }
                    .buttonStyle(RecordAIPrimaryButtonStyle()).disabled(state.locked)
            }
        }.padding(28).frame(width: 470).buttonStyle(RecordAISecondaryButtonStyle())
    }
}
