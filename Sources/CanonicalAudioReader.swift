import Foundation
import AVFoundation

/// Bounded PCM view of canonical AAC streams on their shared 16 kHz timeline.
/// This never creates a derived audio file or changes the original segments.
final class CanonicalAudioReader: @unchecked Sendable {
    enum Failure: Error { case invalidRange, missingStream, unsafePath, unreadableAudio }
    let manifest: BalancedRecordingManifest?
    let durationFrames: Int64
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    static let maximumReadFrames = 65_536
    private let root: URL
    private let streams: [BalancedAudioStream]
    private let gain: Float
    private let originFrame: Int64
    private let lock = NSLock()
    private var opened: [String: (index: Int, file: AVAudioFile)] = [:]

    init(manifestURL: URL, streamIDs: Set<String>? = nil) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= 32 * 1024 * 1024
        else { throw BalancedAudioError.invalidManifest }
        let value = try JSONDecoder().decode(BalancedRecordingManifest.self, from: Data(contentsOf: manifestURL))
        try value.validate()
        let selected: [BalancedAudioStream]
        if let streamIDs {
            guard !streamIDs.isEmpty, streamIDs.isSubset(of: Set(value.streams.map(\.streamID))) else { throw Failure.missingStream }
            selected = value.streams.filter { streamIDs.contains($0.streamID) }
        } else { selected = value.streams }
        manifest = value; durationFrames = value.durationFrames; originFrame = 0
        streams = selected; root = manifestURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        // Preserve the existing Mac two-track mix gain while isolated source
        // reads retain their full level for transcription and source playback.
        gain = selected.count == 1 ? 1 : 0.9 / Float(selected.count)
    }

    /// A read-only range over immutable original descriptors. This is a view,
    /// never a final manifest or a new identity for the original AAC assets.
    init(root: URL, recordingID: UUID, streams: [BalancedAudioStream], startFrame: Int64, endFrame: Int64) throws {
        guard startFrame >= 0, endFrame > startFrame, endFrame <= BalancedAudioSegment.maximumTimelineFrames,
              !streams.isEmpty, streams.count <= 8, Set(streams.map(\.streamID)).count == streams.count,
              streams.reduce(0, { $0 + $1.segments.count }) <= 256 else { throw Failure.invalidRange }
        for stream in streams {
            guard let first = stream.segments.first, first.startFrame == stream.startFrame else { throw Failure.invalidRange }
            var cursor = first.startFrame, index = first.index
            for part in stream.segments {
                guard part.isValid, part.recordingID == recordingID, part.streamID == stream.streamID,
                      part.index == index, part.startFrame == cursor else { throw Failure.invalidRange }
                cursor = part.endFrame; index += 1
            }
        }
        manifest = nil; durationFrames = endFrame - startFrame; originFrame = startFrame
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.streams = streams
        gain = streams.count == 1 ? 1 : 0.9 / Float(streams.count)
    }

    /// Random access opens at most one AAC file per selected stream. Reads span
    /// any segment boundaries; silence outside a source's interval is explicit.
    func read(startFrame: Int64, count: Int) throws -> AVAudioPCMBuffer {
        lock.lock(); defer { lock.unlock() }
        guard startFrame >= 0, startFrame <= durationFrames, count > 0, count <= Self.maximumReadFrames else { throw Failure.invalidRange }
        let frames = Int(min(Int64(count), durationFrames - startFrame))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames))) else { throw Failure.unreadableAudio }
        output.frameLength = AVAudioFrameCount(frames)
        memset(output.floatChannelData![0], 0, frames * MemoryLayout<Float>.size)
        guard frames > 0 else { return output }
        let absoluteStart = originFrame + startFrame
        let ending = absoluteStart + Int64(frames)
        try autoreleasepool {
            for stream in streams {
                var cursor = max(absoluteStart, stream.startFrame)
                let limit = min(ending, stream.endFrame)
                guard cursor < limit else { continue }
                var low = 0, high = stream.segments.count
                while low < high {
                    let middle = (low + high) / 2
                    if stream.segments[middle].endFrame <= cursor { low = middle + 1 } else { high = middle }
                }
                var index = low
                while cursor < limit {
                    guard index < stream.segments.count else { throw Failure.unreadableAudio }
                    let item = stream.segments[index]
                    guard item.startFrame <= cursor, cursor < item.endFrame else { throw Failure.unreadableAudio }
                    let file = try open(item)
                    let position = cursor - item.startFrame
                    if file.framePosition != position { file.framePosition = position }
                    let amount = AVAudioFrameCount(min(item.endFrame, limit) - cursor)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: amount) else { throw Failure.unreadableAudio }
                    try file.read(into: buffer, frameCount: amount)
                    guard buffer.frameLength == amount, let input = buffer.floatChannelData?[0] else { throw Failure.unreadableAudio }
                    let offset = Int(cursor - absoluteStart), target = output.floatChannelData![0]
                    for frame in 0..<Int(amount) { target[offset + frame] += input[frame] * gain }
                    cursor += Int64(amount); index += 1
                }
            }
        }
        return output
    }

    private func open(_ segment: BalancedAudioSegment) throws -> AVAudioFile {
        if let existing = opened[segment.streamID], existing.index == segment.index { return existing.file }
        let url = root.appendingPathComponent(segment.streamID, isDirectory: true).appendingPathComponent(segment.filename)
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw Failure.unsafePath }
        try BalancedAudioIO.validateFile(url, segment: segment, decode: false)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              file.length == segment.validFrames, file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1 else { throw Failure.unreadableAudio }
        opened[segment.streamID] = (segment.index, file)
        return file
    }
}
