import Foundation
import AVFoundation

@main struct CantoneseLiveSessionSmoke {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments, root = URL(fileURLWithPath:CommandLine.arguments[4])
        let library = try MeetingLibrary(root:root)
        let state = AppState(storageURL:root,connectionNamespace:"live-yue-fixture-")
        let record = try library.save(MeetingRecord(title:"Synthetic Cantonese live test",language:"yue",status:.recording))
        state.history = try library.list()
        state.select(record.id);state.language = "yue";state.recording = true;state.bindRecordingContext(to:record.id)
        let source = try AVAudioFile(forReading:URL(fileURLWithPath:args[3]))
        precondition(source.processingFormat.sampleRate == 16000 && source.processingFormat.channelCount == 1)
        let pcm = AVAudioPCMBuffer(pcmFormat:source.processingFormat,frameCapacity:AVAudioFrameCount(source.length))!
        try source.read(into:pcm);let samples = Array(UnsafeBufferPointer(start:pcm.floatChannelData![0],count:Int(pcm.frameLength)))
        let session = LiveTranscriptionSession();var types:[String] = [];var firstCaption:Date?;var commits = 0
        var mainPreviewSeen = false, miniPreviewSeen = false
        session.onEvent = { event in
            Task { @MainActor in
                types.append(event.type)
                state.handleLiveEvent(event,meetingID:record.id)
                if ["partial","commit"].contains(event.type), !event.text.isEmpty {
                    firstCaption = firstCaption ?? Date()
                    mainPreviewSeen = mainPreviewSeen || !state.liveText.isEmpty
                    let mini = state.miniTranscriptPreview
                    miniPreviewSeen = miniPreviewSeen || !mini.confirmed.isEmpty || !mini.partial.isEmpty
                    if event.type == "commit" { commits += 1 }
                }
            }
        }
        try session.start(model:URL(fileURLWithPath:args[2]),executable:URL(fileURLWithPath:args[1]),language:"yue")
        let started = Date()
        let feeder = Task.detached {
            for round in 0..<2 {
                for begin in stride(from:0,to:samples.count,by:1600) {
                    let end = min(samples.count,begin+1600)
                    session.append(Array(samples[begin..<end]))
                    try await Task.sleep(nanoseconds:UInt64(Double(end-begin)/16000*1_000_000_000))
                }
                if round == 0 { try await Task.sleep(nanoseconds:3_000_000_000) }
            }
        }
        try await feeder.value
        precondition(firstCaption != nil && mainPreviewSeen && miniPreviewSeen,"captions must be visible before capture finishes")
        await session.finish();try await Task.sleep(nanoseconds:150_000_000)
        precondition(types.contains("done") && !types.contains("error") && commits>=2,"session failed: \(types)")
        let saved = try library.load(record.id)
        precondition(saved.text.isEmpty && saved.status == .recording,"live captions must not become a final transcript")
        precondition(!saved.previewText.isEmpty && !saved.liveUtterances.isEmpty)
        precondition(saved.previewEngine == "qwen3-asr-live-bounded")
        precondition(saved.liveUtterances.allSatisfy { $0.start>=0 && $0.end >= $0.start })
        let adapter = MacLibrarySyncAdapter(library:library), owner = UUID()
        try adapter.activate(userId:owner);try adapter.enrollAll(userId:owner)
        let projected = try adapter.values(userId:owner)
        precondition(projected.isEmpty,"active live text cannot enter account sync")
        state.recording = false
        let report:[String:Any] = ["status":"PASS","mainPreviewSeenBeforeStop":mainPreviewSeen,"miniPreviewSeenBeforeStop":miniPreviewSeen,"committedUtterances":saved.liveUtterances.count,"firstCaptionSeconds":firstCaption!.timeIntervalSince(started),"previewSaved":true,"noFinalTranscriptPublished":true,"noLiveSyncPayload":true]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
        print("PASS production LiveTranscriptionSession → main and mini subtitle state → persisted preview; live text excluded from final/sync")
    }
}
