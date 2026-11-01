import SwiftUI

/// Presents exactly the default transcript payload, without Markdown control characters.
struct SyncContentPreview: View {
    @ObservedObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(state.title).font(AppTypography.heading)
                if let record = state.current {
                    HStack {
                        Text(record.created, format: .dateTime.year().month().day().hour().minute())
                        Text("· \(Int(record.duration)) 秒")
                    }.font(AppTypography.secondary).foregroundStyle(.secondary)
                }
                if let record = state.current, record.hasCurrentParagraphs, record.text == state.text {
                    ForEach(record.transcriptParagraphs) { paragraph in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(record.paragraphSpeaker(paragraph)).fontWeight(.semibold)
                                if let start = paragraph.start { Text("\(Int(start)) 秒").foregroundStyle(.secondary) }
                            }.font(AppTypography.secondary)
                            Text(paragraph.text).font(AppTypography.body).lineSpacing(6)
                        }
                    }
                } else { Text(state.text).font(AppTypography.body).lineSpacing(6) }
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(16)
        }.background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecordAITheme.border, lineWidth: 1))
            .accessibilityLabel("同步正文预览")
    }
}
