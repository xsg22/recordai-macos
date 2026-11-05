import Foundation
import AVFoundation

/// One source on the common 16 kHz capture timeline.
/// The owner serializes calls and resamples source buffers before appending.
final class MacSegmentedTrackWriter {
    private let session: ResilientRecordingSession
    private let startFrame: Int64
    private var cursor: Int64
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    init(directory: URL, recordingID: UUID, streamID: String, startFrame: Int64,
         onSealed: @escaping (ResilientRecordingSegmentDescriptor) -> Void = { _ in }) throws {
        guard startFrame >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        // If an earlier encoder is draining, propagate the busy error so the
        // asynchronous caller can retry without blocking audio or UI queues.
        let acquired = try ResilientRecordingSession(directory: directory, id: recordingID)
        let recovery = try ResilientRecordingSession.inspect(directory: directory)
        guard recovery.id == recordingID, recovery.storedState != .finished, recovery.unreadableIndices.isEmpty,
              recovery.frames <= Int64.max - startFrame else { throw CocoaError(.fileReadCorruptFile) }
        self.startFrame = startFrame
        cursor = startFrame + recovery.frames
        session = acquired
        try session.configureSealedOutput(streamID: streamID, streamStartFrame: startFrame, onChunkSealed: onSealed)
        try session.startOrResume()
    }

    func append(_ samples: [Float], startFrame: Int64) throws {
        guard startFrame >= self.startFrame, startFrame <= Int64.max - Int64(samples.count) else { throw CocoaError(.fileReadCorruptFile) }
        let ending = startFrame + Int64(samples.count)
        guard ending > cursor else { return }
        while cursor < startFrame {
            let count = Int(min(8192, startFrame - cursor))
            try write([Float](repeating: 0, count: count))
        }
        let offset = Int(max(0, cursor - startFrame))
        var index = offset
        while index < samples.count {
            let end = min(samples.count, index + 8192)
            try write(Array(samples[index..<end])); index = end
        }
    }
    private func write(_ samples: [Float]) throws {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count) }
        try session.append(buffer); cursor += Int64(samples.count)
    }
    func pause() throws { try session.pause() }
    func resume() throws { try session.startOrResume() }
    func pad(toFrame ending: Int64) throws {
        while cursor < ending { try write([Float](repeating: 0, count: Int(min(8192, ending - cursor)))) }
    }
    func finish() throws -> URL { try session.finishSegments() }
}

/// Resamples one continuous source at a time, preserving its offsets on the
/// recording timeline. A device restart or source switch closes the old
/// converter before a new one is anchored, so missing time becomes silence.
final class MacSegmentedSourceWriter {
    private let track: MacSegmentedTrackWriter
    private var converter: ResilientRecordingConverter?
    private var sourceFormat: AVAudioFormat?
    private var expectedSourceTime: Double?
    private var nextFrame: Int64 = 0
    private var paused = false

    init(directory: URL, recordingID: UUID, streamID: String, startFrame: Int64,
         onSealed: @escaping (ResilientRecordingSegmentDescriptor) -> Void = { _ in }) throws {
        track = try MacSegmentedTrackWriter(directory: directory, recordingID: recordingID, streamID: streamID, startFrame: startFrame, onSealed: onSealed)
    }
    func append(_ buffer: AVAudioPCMBuffer, offset: TimeInterval) throws {
        guard !paused, offset.isFinite, offset >= 0, buffer.format.sampleRate > 0,
              offset <= Double(Int64.max / 16_000) else { throw CocoaError(.fileReadCorruptFile) }
        let discontinuity = expectedSourceTime.map { abs(offset - $0) > 0.01 } ?? false
        if converter == nil || sourceFormat != buffer.format || discontinuity {
            try flushConverter()
            converter = try ResilientRecordingConverter(source: buffer.format)
            sourceFormat = buffer.format
            nextFrame = Int64((offset * 16_000).rounded())
        }
        expectedSourceTime = offset + Double(buffer.frameLength) / buffer.format.sampleRate
        for output in try converter!.convert(buffer) { try appendConverted(output) }
    }
    func pause() throws {
        guard !paused else { return }
        try flushConverter(); try track.pause(); paused = true
    }
    func resume() throws {
        guard paused else { return }
        try track.resume(); paused = false
    }
    func appendSilence(untilFrame ending: Int64) throws {
        guard !paused else { return }
        try flushConverter(); try track.pad(toFrame: ending)
    }
    func finish(untilFrame ending: Int64? = nil) throws -> URL {
        if paused, ending != nil { try track.resume(); paused = false }
        try flushConverter()
        if let ending { try track.pad(toFrame: ending) }
        return try track.finish()
    }
    private func flushConverter() throws {
        if let converter { for output in try converter.finish() { try appendConverted(output) } }
        converter = nil; sourceFormat = nil; expectedSourceTime = nil
    }
    private func appendConverted(_ buffer: AVAudioPCMBuffer) throws {
        guard let data = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        let count = Int(buffer.frameLength)
        guard Int64(count) <= Int64.max - nextFrame else { throw CocoaError(.fileReadCorruptFile) }
        try track.append(Array(UnsafeBufferPointer(start: data, count: count)), startFrame: nextFrame)
        nextFrame += Int64(count)
    }
}
