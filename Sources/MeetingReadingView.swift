import SwiftUI

struct MeetingReadingView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 18) {
            if state.recording { RecordingTransportView(state: state) }
            else if state.audio != nil { NativePlaybackBar(state: state) }
            RecordingCanvasView(state: state)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
