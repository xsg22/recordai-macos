import SwiftUI

struct RecordingLibraryRow: View {
    let record: MeetingRecord
    let selected: Bool
    let metadata: String
    var groupName: String? = nil
    private var symbol: String {
        if record.status == .completed || record.status == .recorded { return record.stateModel.origin.symbol }
        return record.status == .recording ? "record.circle" : "clock"
    }
    private var iconColor: Color { record.status == .recording ? .red : record.status == .completed ? RecordAITheme.ink : .orange }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 14, height: 18).foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 7) {
                Text(record.title).lineLimit(1).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? RecordAITheme.selectionInk : RecordAITheme.ink)
                HStack(spacing: 6) {
                    Text(metadata).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    if let groupName {
                        Text(groupName)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RecordAITheme.selection, in: RoundedRectangle(cornerRadius: 4))
                            .help(groupName)
                    }
                }.font(.system(size: 11)).foregroundStyle(RecordAITheme.muted)
            }
            Spacer(minLength: 0)
        }.frame(minHeight: 46, alignment: .top).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? RecordAITheme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
    }
}
