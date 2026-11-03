import Foundation

/// A session's sources are independent of the next recording's default mode.
struct RecordingSources: Codable, Equatable, Sendable {
    var microphone: Bool
    var systemAudio: Bool
    static let muted = Self(microphone: false, systemAudio: false)
    var isMuted: Bool { !microphone && !systemAudio }
    init(microphone: Bool, systemAudio: Bool) { self.microphone = microphone; self.systemAudio = systemAudio }
    init(mode: MeetingRecordingMode) { microphone = mode.needsMicrophone; systemAudio = mode.needsSystemAudio }
    func contains(_ kind: MeetingAudioTrack.Kind) -> Bool { kind == .microphone ? microphone : systemAudio }
    func toggling(_ kind: MeetingAudioTrack.Kind) -> Self {
        var result = self
        if kind == .microphone { result.microphone.toggle() } else { result.systemAudio.toggle() }
        return result
    }
}

/// Source mute intervals are clipped without removing time. Pause intervals are
/// handled separately by MeetingCaptureTimeline, which does remove paused time.
struct RecordingSourceTimeline {
    struct Event: Codable { let timestamp: TimeInterval; let sources: RecordingSources }
    private(set) var events: [Event]
    init(started: TimeInterval, sources: RecordingSources) { events = [Event(timestamp: started, sources: sources)] }
    mutating func setSources(_ sources: RecordingSources, at timestamp: TimeInterval) {
        guard let last = events.last, last.sources != sources else { return }
        events.append(Event(timestamp: max(timestamp, last.timestamp), sources: sources))
    }
    func slices(kind: MeetingAudioTrack.Kind, at timestamp: TimeInterval, frames: Int, sampleRate: Double) -> [Range<Int>] {
        guard timestamp.isFinite, sampleRate > 0, frames > 0 else { return [] }
        let ending = timestamp + Double(frames) / sampleRate
        return events.indices.compactMap { index in
            guard events[index].sources.contains(kind) else { return nil }
            let start = max(timestamp, events[index].timestamp)
            let end = min(ending, index + 1 < events.count ? events[index + 1].timestamp : ending)
            guard end > start else { return nil }
            let lower = max(0, min(frames, Int(((start - timestamp) * sampleRate).rounded())))
            let upper = max(lower, min(frames, Int(((end - timestamp) * sampleRate).rounded())))
            return lower < upper ? lower..<upper : nil
        }
    }
}

struct MiniTranscriptPreview: Equatable {
    let confirmed: String
    let partial: String
    init(text: String, partial: String) {
        self.partial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        var committed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !self.partial.isEmpty, committed.hasSuffix(self.partial) { committed.removeLast(self.partial.count) }
        confirmed = committed.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}
