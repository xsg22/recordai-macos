import SwiftUI

/// Only recording organization is exposed; legacy content stays in the saved record.
struct MeetingInspector: View {
    @ObservedObject var state: AppState
    var body: some View {
        ScrollView {
            RecordingOrganizationPanel(state: state)
                .font(AppTypography.secondary).padding(.leading, 24).padding(.vertical, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .leading) { Rectangle().fill(RecordAITheme.border).frame(width: 1) }
    }
}
