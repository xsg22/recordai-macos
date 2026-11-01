import SwiftUI

struct RecordingLibraryRow: View {
    let record: MeetingRecord
    let selected: Bool
    let metadata: String
    private var symbol: String {
        if record.status == .completed { return "mic" }
        return record.status == .recording ? "record.circle" : "clock"
    }
    private var iconColor: Color { record.status == .completed ? RecordAITheme.ink : .orange }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 14, height: 18).foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 7) {
                Text(record.title).lineLimit(1).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? RecordAITheme.selectionInk : RecordAITheme.ink)
                Text(metadata).font(.system(size: 12)).foregroundStyle(RecordAITheme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.frame(minHeight: 46, alignment: .top).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RecordAITheme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}
