import SwiftUI

struct MeetingAttachmentsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("相关内容", systemImage: "paperclip").font(AppTypography.heading)
                Spacer()
                Button("添加") { state.chooseAttachment() }.buttonStyle(.plain).foregroundStyle(RecordAITheme.accent).disabled(state.locked)
            }
            ForEach(state.current?.attachments ?? []) { attachment in
                HStack(spacing: 10) {
                    Image(systemName: "doc").foregroundStyle(RecordAITheme.accent)
                    Button { state.openAttachment(attachment) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(attachment.displayName).lineLimit(2).multilineTextAlignment(.leading)
                            Text("本地附件 · " + ByteCountFormatter.string(fromByteCount: attachment.bytes, countStyle: .file))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Menu {
                        Button("打开") { state.openAttachment(attachment) }
                        Button("在 Finder 中显示") { state.openAttachment(attachment, reveal: true) }
                        Button("移除附件", role: .destructive) { state.removeAttachment(attachment.id) }.disabled(state.locked)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("附件操作")
                }.padding(12).background(RecordAITheme.quiet, in: RoundedRectangle(cornerRadius: 9))
            }
            if state.current?.attachments.isEmpty == true {
                Text("添加会议相关的本地文件。").font(AppTypography.secondary).foregroundStyle(.secondary)
            }
        }
    }
}
