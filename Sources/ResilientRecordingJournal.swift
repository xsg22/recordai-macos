import Foundation
import AVFoundation
import Darwin
import CryptoKit

/// Immutable identity of a committed AAC segment. `url` is local-only and
/// must never be trusted as a remote path. Frame positions use the recording
/// stream's 16 kHz timeline, not the source device's hardware clock.
struct ResilientRecordingSegmentDescriptor: Codable, Equatable {
    let recordingID: UUID
    let streamID: String
    let index: Int
    let startFrame: Int64
    let validFrames: Int64
    let sampleRate: Int
    let channels: Int
    let bitRate: Int
    let byteCount: Int64
    let sha256: String
    let url: URL
}

/// Normalize hardware-specific input before it is written to the journal.
/// A converter belongs to one uninterrupted hardware-format epoch.
final class ResilientRecordingConverter {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    private var sourceFrames: Int64 = 0
    private var outputFrames: Int64 = 0
    private var leadingFrames: Int
    private let passthrough: Bool
    private(set) var finished = false
    init(source: AVAudioFormat) throws {
        guard source.sampleRate.isFinite, source.sampleRate > 0, source.channelCount > 0,
              let converter = AVAudioConverter(from: source, to: target) else { throw CocoaError(.fileReadUnsupportedScheme) }
        converter.primeMethod = .none
        self.converter = converter
        self.passthrough = source == target
        // primeInfo is meaningful for resampling; some same-rate converters
        // report uninitialized values, so do not read it for channel mixing.
        self.leadingFrames = source.sampleRate == 16_000 ? 0 : Int((Double(converter.primeInfo.leadingFrames) * 16_000 / source.sampleRate).rounded())
    }
    func convert(_ input: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        guard !finished, input.format == converter.inputFormat else { throw CocoaError(.fileReadCorruptFile) }
        sourceFrames += Int64(input.frameLength)
        if passthrough { outputFrames += Int64(input.frameLength); return [input] }
        var supplied = false
        let result = try drain { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        return try normalize(result, final: false)
    }
    func finish() throws -> [AVAudioPCMBuffer] {
        guard !finished else { return [] }
        finished = true
        if passthrough { return [] }
        return try normalize(drain { _, status in status.pointee = .endOfStream; return nil }, final: true)
    }
    private func normalize(_ buffers: [AVAudioPCMBuffer], final: Bool) throws -> [AVAudioPCMBuffer] {
        let exact = Double(sourceFrames) * target.sampleRate / converter.inputFormat.sampleRate
        let frameLimit = Int64(final ? exact.rounded() : exact.rounded(.down))
        var result: [AVAudioPCMBuffer] = []
        for buffer in buffers {
            let discard = min(leadingFrames, Int(buffer.frameLength)); leadingFrames -= discard
            let count = min(Int(buffer.frameLength) - discard, max(0, Int(frameLimit - outputFrames)))
            guard count > 0 else { continue }
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count)),
                  let source = buffer.floatChannelData?[0], let destination = output.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
            output.frameLength = AVAudioFrameCount(count)
            destination.update(from: source.advanced(by: discard), count: count)
            outputFrames += Int64(count); result.append(output)
        }
        return result
    }
    private func drain(_ supply: AVAudioConverterInputBlock) throws -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { throw CocoaError(.fileReadCorruptFile) }
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: supply)
            if let error { throw error }
            if output.frameLength > 0 { buffers.append(output) }
            switch status {
            case .inputRanDry, .endOfStream: return buffers
            case .error: throw CocoaError(.fileReadCorruptFile)
            case .haveData: guard output.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            @unknown default: throw CocoaError(.fileReadCorruptFile)
            }
        }
    }
}

/// Storage primitive for one recording. Input must already be mono Float32 PCM
/// at 16 kHz. Incomplete CAF chunks remain readable after a process kill.
/// This primitive does not manage recording UI, permissions, ASR, or transport.
final class ResilientRecordingJournal {
    enum JournalError: Error { case encoderBacklogExceeded }
    struct Chunk {
        let index: Int
        let url: URL
        let frames: Int64
    }
    struct Scan {
        let chunks: [Chunk]
        let unreadableIndices: [Int]
    }
    /// Inspect only an already committed AAC file. This is bounded-memory and
    /// intended once per segment, not for rescanning the entire recording on
    /// each audio callback. Only pass segments produced by this journal's
    /// 32 kbps encoder; callers must persist the manifest before advertising.
    static func describeSealedAAC(_ chunk: Chunk, recordingID: UUID, streamID: String,
                                  startFrame: Int64, allowExistingPCM: Bool = false) throws -> ResilientRecordingSegmentDescriptor {
        guard !streamID.isEmpty, streamID.utf8.count <= 48,
              streamID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              chunk.index >= 0, chunk.index < 100_000, startFrame >= 0, startFrame <= Int64.max - 160_000,
              chunk.frames > 0, chunk.frames <= framesPerChunk,
              chunk.url.lastPathComponent == String(format: "%08d.m4a", chunk.index),
              chunk.url.pathExtension.lowercased() == "m4a",
              (allowExistingPCM || !FileManager.default.fileExists(atPath: chunk.url.deletingPathExtension().appendingPathExtension("caf").path))
        else { throw CocoaError(.fileReadCorruptFile) }
        let audio = try AVAudioFile(forReading: chunk.url)
        guard audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              audio.processingFormat.sampleRate == rate, audio.processingFormat.channelCount == 1,
              audio.length == chunk.frames else { throw CocoaError(.fileReadCorruptFile) }
        try validateAudio(chunk.url, expectedFrames: chunk.frames)
        let file = try FileHandle(forReadingFrom: chunk.url)
        defer { try? file.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while let data = try file.read(upToCount: 65_536), !data.isEmpty {
            bytes += Int64(data.count); hash.update(data: data)
        }
        guard bytes > 0, bytes <= 256 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return ResilientRecordingSegmentDescriptor(recordingID: recordingID, streamID: streamID,
            index: chunk.index, startFrame: startFrame, validFrames: chunk.frames,
            sampleRate: 16_000, channels: 1, bitRate: 32_000, byteCount: bytes, sha256: digest, url: chunk.url)
    }
    private static let rate: Double = 16_000
    private static let framesPerChunk: Int64 = 160_000
    private let root: URL
    private let lock = NSLock()
    private let encoder = DispatchQueue(label: "talktuck.recording.journal.encoder")
    private var writer: AVAudioFile?
    private var currentFrames: Int64 = 0
    private var nextIndex: Int
    private var currentIndex: Int?
    private var encoderPending = 0
    private var encoderFailure: Error?
    private let maximumPendingEncodes = 8
    private let encodeChunk: (Int, URL) throws -> Void
    private var sealedContext: (id: UUID, stream: String, callback: (ResilientRecordingSegmentDescriptor) -> Void)?
    private var timelineFrame: Int64 = 0
    private var currentStartFrame: Int64 = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    init(directory: URL, encodeChunk: ((Int, URL) throws -> Void)? = nil) throws {
        root = directory
        self.encodeChunk = encodeChunk ?? Self.compress
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        nextIndex = (names.compactMap { Self.index(for: $0) }.max() ?? -1) + 1
    }

    /// Completed chunks plus any interrupted CAF tail, in recording order.
    /// When both exist the CAF is authoritative until compression is committed.
    static func recover(directory: URL) throws -> [Chunk] {
        let result = try scan(directory: directory)
        guard result.unreadableIndices.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return result.chunks
    }
    /// An unreadable tail must not hide earlier usable audio; callers must
    /// explicitly report unreadable indices before allowing finalization.
    static func scan(directory: URL) throws -> Scan {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let indices = Set(names.compactMap { index(for: $0) }).sorted()
        guard let last = indices.last else { return Scan(chunks: [], unreadableIndices: []) }
        guard last < 1_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        var chunks: [Chunk] = [], unreadable: [Int] = []
        for index in 0...last {
            let base = String(format: "%08d", index)
            let raw = directory.appendingPathComponent(base + ".caf")
            let compressed = directory.appendingPathComponent(base + ".m4a")
            let candidates = [raw, compressed].filter { FileManager.default.fileExists(atPath: $0.path) }
            let selected: Chunk? = autoreleasepool {
                for url in candidates {
                    guard let input = try? AVAudioFile(forReading: url), input.length > 0,
                          input.processingFormat.sampleRate == rate, input.processingFormat.channelCount == 1 else { continue }
                    return Chunk(index: index, url: url, frames: input.length)
                }
                return nil
            }
            if let selected { chunks.append(selected) } else { unreadable.append(index) }
        }
        return Scan(chunks: chunks, unreadableIndices: unreadable)
    }

    /// Build a conventional M4A without replacing an existing file or removing
    /// source chunks. The caller must persist and verify its index separately.
    static func assemble(_ chunks: [Chunk], destination: URL) throws {
        guard !chunks.isEmpty, destination.pathExtension.lowercased() == "m4a",
              !FileManager.default.fileExists(atPath: destination.path),
              chunks.enumerated().allSatisfy({ $0.offset == $0.element.index }) else { throw CocoaError(.fileWriteFileExists) }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".assemble-" + UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: staging) }
        let frames: Int64 = try autoreleasepool {
            let output = try AVAudioFile(forWriting: staging, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            var total: Int64 = 0
            for chunk in chunks {
                let input = try AVAudioFile(forReading: chunk.url)
                guard input.length == chunk.frames, input.processingFormat.sampleRate == rate,
                      input.processingFormat.channelCount == 1,
                      let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)
                else { throw CocoaError(.fileReadCorruptFile) }
                while input.framePosition < input.length {
                    try input.read(into: buffer)
                    guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    try output.write(from: buffer); total += Int64(buffer.frameLength)
                }
            }
            return total
        }
        try validateAudio(staging, expectedFrames: frames)
        let handle = try FileHandle(forWritingTo: staging); try handle.synchronize(); try handle.close()
        try FileManager.default.moveItem(at: staging, to: destination)
        let fd = open(parent.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let committed = fsync(fd) == 0; close(fd)
        guard committed else { throw CocoaError(.fileWriteUnknown) }
    }

    func append(_ buffer: AVAudioPCMBuffer, allowingBackloggedPCM: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        if let encoderFailure, !(allowingBackloggedPCM && encoderFailure is JournalError) { throw encoderFailure }
        guard buffer.format == format, let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        var offset = 0
        while offset < Int(buffer.frameLength) {
            if writer == nil { try openChunk() }
            let count = min(Int(buffer.frameLength) - offset, Int(Self.framesPerChunk - currentFrames))
            guard Int64(count) <= Int64.max - timelineFrame else { throw CocoaError(.fileWriteUnknown) }
            guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let target = slice.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
            slice.frameLength = AVAudioFrameCount(count)
            target.update(from: channel.advanced(by: offset), count: count)
            try writer?.write(from: slice)
            currentFrames += Int64(count); offset += count
            timelineFrame += Int64(count)
            if currentFrames == Self.framesPerChunk { closeChunk() }
        }
    }

    /// Seal the current chunk, e.g. on pause or finish. Encoding may continue in background.
    func checkpoint() {
        lock.lock(); defer { lock.unlock() }
        closeChunk()
    }
    func waitForCompression() { encoder.sync {} }
    func checkEncoderFailure() throws {
        lock.lock(); defer { lock.unlock() }
        if let encoderFailure { throw encoderFailure }
    }
    /// Configure only while paused. The callback is a hint and runs on the
    /// encoder queue; it must return promptly and must not re-enter the journal.
    func configureSealedOutput(recordingID: UUID, streamID: String, nextFrame: Int64,
                               onChunkSealed: @escaping (ResilientRecordingSegmentDescriptor) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard writer == nil, encoderPending == 0, nextFrame >= 0 else { throw CocoaError(.fileWriteUnknown) }
        timelineFrame = nextFrame
        sealedContext = (recordingID, streamID, onChunkSealed)
    }
    /// Convert interrupted PCM tails before capture is resumed. Failed or
    /// conflicting outputs preserve the original CAF and stop recovery.
    func recoverPendingPCM(_ chunks: [Chunk], recordingID: UUID, streamID: String, streamStartFrame: Int64,
                           onChunkSealed: (ResilientRecordingSegmentDescriptor) -> Void) throws {
        var cursor = streamStartFrame
        for chunk in chunks {
            guard chunk.frames > 0, chunk.frames <= Int64.max - cursor else { throw CocoaError(.fileReadCorruptFile) }
            if chunk.url.pathExtension.lowercased() == "caf" {
                let item: ResilientRecordingSegmentDescriptor = try autoreleasepool {
                    let staleAAC = root.appendingPathComponent(String(format: "%08d.m4a", chunk.index))
                    let committedDescriptor = root.appendingPathComponent(String(format: "%08d.segment.json", chunk.index))
                    if FileManager.default.fileExists(atPath: staleAAC.path) {
                        if FileManager.default.fileExists(atPath: committedDescriptor.path) {
                            // Published AAC keeps its identity. Validate against the
                            // durable descriptor, and retain the redundant PCM.
                            let item = try Self.describeSealedAAC(Chunk(index: chunk.index, url: staleAAC, frames: chunk.frames),
                                recordingID: recordingID, streamID: streamID, startFrame: cursor, allowExistingPCM: true)
                            try Self.persistDescriptor(item, directory: root)
                            try Self.preserveRecoveryFile(chunk.url, under: "sealed-pcm-preserved", root: root)
                            return item
                        }
                        // Without committed metadata the AAC has never been
                        // announced. Preserve it and recover from authoritative PCM.
                        try Self.preserveRecoveryFile(staleAAC, under: "unsealed-preserved", root: root)
                    }
                    try encodeChunk(chunk.index, root)
                    let url = root.appendingPathComponent(String(format: "%08d.m4a", chunk.index))
                    let item = try Self.describeSealedAAC(Chunk(index: chunk.index, url: url, frames: chunk.frames),
                                                          recordingID: recordingID, streamID: streamID, startFrame: cursor)
                    try Self.persistDescriptor(item, directory: root)
                    return item
                }
                onChunkSealed(item)
            }
            cursor += chunk.frames
        }
    }

    private func openChunk() throws {
        let index = nextIndex
        let raw = root.appendingPathComponent(String(format: "%08d.caf", index))
        guard !FileManager.default.fileExists(atPath: raw.path) else { throw CocoaError(.fileWriteFileExists) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        writer = try AVAudioFile(forWriting: raw, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        currentIndex = index; nextIndex += 1; currentFrames = 0; currentStartFrame = timelineFrame
    }
    private func closeChunk() {
        guard let index = currentIndex, writer != nil else { return }
        let frames = currentFrames, start = currentStartFrame, context = sealedContext
        writer = nil; currentIndex = nil; currentFrames = 0
        guard encoderFailure == nil, encoderPending < maximumPendingEncodes else {
            if encoderFailure == nil { encoderFailure = JournalError.encoderBacklogExceeded }
            return // The closed PCM chunk stays on disk for recovery.
        }
        encoderPending += 1
        let root = self.root
        encoder.async { [self] in
            let failure: Error?
            var descriptor: ResilientRecordingSegmentDescriptor?
            do {
                try encodeChunk(index, root)
                if let context {
                    let url = root.appendingPathComponent(String(format: "%08d.m4a", index))
                    let item = try Self.describeSealedAAC(Chunk(index: index, url: url, frames: frames),
                                                          recordingID: context.id, streamID: context.stream, startFrame: start)
                    try Self.persistDescriptor(item, directory: root)
                    descriptor = item
                }
                failure = nil
            }
            catch { failure = error }
            lock.lock(); encoderPending -= 1
            if encoderFailure == nil { encoderFailure = failure }
            lock.unlock()
            if let descriptor, let context { context.callback(descriptor) }
        }
    }
    private struct StoredDescriptor: Codable {
        let recordingID: UUID, streamID: String, index: Int, startFrame: Int64, validFrames: Int64
        let sampleRate: Int, channels: Int, bitRate: Int, byteCount: Int64, sha256: String
        init(_ item: ResilientRecordingSegmentDescriptor) {
            recordingID = item.recordingID; streamID = item.streamID; index = item.index
            startFrame = item.startFrame; validFrames = item.validFrames; sampleRate = item.sampleRate
            channels = item.channels; bitRate = item.bitRate; byteCount = item.byteCount; sha256 = item.sha256
        }
    }
    private static func preserveRecoveryFile(_ url: URL, under name: String, root: URL) throws {
        let saved = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: saved.appendingPathComponent(url.lastPathComponent))
        for folder in [saved, saved.deletingLastPathComponent(), root] {
            let fd = open(folder.path, O_RDONLY)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let synced = fsync(fd) == 0; close(fd)
            guard synced else { throw CocoaError(.fileWriteUnknown) }
        }
    }
    fileprivate static func persistDescriptor(_ descriptor: ResilientRecordingSegmentDescriptor, directory: URL) throws {
        let url = directory.appendingPathComponent(String(format: "%08d.segment.json", descriptor.index))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(StoredDescriptor(descriptor))
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { throw CocoaError(.fileWriteFileExists) }
        } else {
            try data.write(to: url, options: .atomic)
        }
        let file = try FileHandle(forWritingTo: url); try file.synchronize(); try file.close()
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private static func compress(index: Int, directory: URL) throws {
        let base = String(format: "%08d", index)
        let raw = directory.appendingPathComponent(base + ".caf")
        let destination = directory.appendingPathComponent(base + ".m4a")
        let staging = directory.appendingPathComponent(base + "." + UUID().uuidString + ".partial.m4a")
        // Never replace an existing chunk. A failed compression leaves the CAF untouched.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        defer { try? FileManager.default.removeItem(at: staging) }
        let sourceFrames: Int64 = try autoreleasepool {
            let source = try AVAudioFile(forReading: raw)
            guard source.length > 0, source.processingFormat.sampleRate == rate,
                  source.processingFormat.channelCount == 1 else { throw CocoaError(.fileReadCorruptFile) }
            let output = try AVAudioFile(forWriting: staging, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096) else { throw CocoaError(.fileReadCorruptFile) }
            while source.framePosition < source.length {
                try source.read(into: buffer)
                guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(from: buffer)
            }
            return source.length
        }
        try validateAudio(staging, expectedFrames: sourceFrames)
        let handle = try FileHandle(forWritingTo: staging); try handle.synchronize(); try handle.close()
        try FileManager.default.moveItem(at: staging, to: destination)
        // If directory metadata cannot be made durable, keep both copies. A file
        // whose rename disappears after power loss must never be the only copy.
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { return }
        let committed = fsync(directoryFD) == 0
        close(directoryFD)
        guard committed else { return }
        try FileManager.default.removeItem(at: raw)
    }
    private static func index(for name: String) -> Int? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, ["caf", "m4a"].contains(String(parts[1])),
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(parts[0])
    }
    private static func validateAudio(_ url: URL, expectedFrames: Int64) throws {
        let input = try AVAudioFile(forReading: url)
        guard input.length == expectedFrames, input.processingFormat.sampleRate == rate,
              input.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)
        else { throw CocoaError(.fileReadCorruptFile) }
        var decoded: Int64 = 0
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            decoded += Int64(buffer.frameLength)
        }
        guard decoded == expectedFrames else { throw CocoaError(.fileReadCorruptFile) }
    }
}

/// Durable lifecycle for one recording. Starting the microphone and presenting
/// recovery choices belong to the app; reopening never starts capture itself.
final class ResilientRecordingSession: @unchecked Sendable {
    enum State: String, Codable { case active, paused, finished }
    private struct StreamBinding: Codable, Equatable {
        let recordingID: UUID
        let streamID: String
        let startFrame: Int64
    }
    private struct FinalSegment: Encodable {
        let recordingID: UUID, streamID: String, index: Int, startFrame: Int64, validFrames: Int64
        let sampleRate: Int, channels: Int, bitRate: Int, byteCount: Int64, sha256: String
        init(_ item: ResilientRecordingSegmentDescriptor) {
            recordingID = item.recordingID; streamID = item.streamID; index = item.index
            startFrame = item.startFrame; validFrames = item.validFrames; sampleRate = item.sampleRate
            channels = item.channels; bitRate = item.bitRate; byteCount = item.byteCount; sha256 = item.sha256
        }
    }
    private struct FinalStream: Encodable {
        let streamID: String
        let startFrame: Int64
        let segments: [FinalSegment]
    }
    private struct FinalManifest: Encodable {
        let schemaVersion = 1
        let formatID = "talktuck.aac16k.v1"
        let recordingID: UUID
        let streams: [FinalStream]
    }
    private struct Manifest: Codable {
        let id: UUID
        var state: State
        var outputName: String?
        var quarantinedTail: [Int]?
    }
    struct Recovery {
        let id: UUID
        let storedState: State
        let frames: Int64
        let unreadableIndices: [Int]
        let quarantinedTail: [Int]
        var requiresUserChoice: Bool { storedState != .finished }
    }
    private let directory: URL
    private let manifestURL: URL
    private let encodeChunkOverride: ((Int, URL) throws -> Void)?
    private var journal: ResilientRecordingJournal
    private let lockFD: Int32
    private var manifest: Manifest
    private var captureAuthorized = false
    private let lock = NSLock()
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return manifest.state == .finished }

    init(directory: URL, id: UUID, encodeChunk: ((Int, URL) throws -> Void)? = nil) throws {
        self.directory = directory
        self.encodeChunkOverride = encodeChunk
        manifestURL = directory.appendingPathComponent("session.json")
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(".session.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw CocoaError(.fileWriteFileExists) }
        var acquired = true
        defer { if acquired { flock(fd, LOCK_UN); close(fd) } }
        if manager.fileExists(atPath: manifestURL.path) {
            let loaded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard loaded.id == id else { throw CocoaError(.fileReadCorruptFile) }
            manifest = loaded
        } else {
            let contents = try manager.contentsOfDirectory(atPath: directory.path).filter { $0 != ".session.lock" }
            guard contents.isEmpty else { throw CocoaError(.fileWriteFileExists) }
            manifest = Manifest(id: id, state: .paused)
            try Self.save(manifest, to: manifestURL)
        }
        journal = try ResilientRecordingJournal(directory: directory, encodeChunk: encodeChunk)
        lockFD = fd; acquired = false
    }
    deinit {
        // The encoder owns the closed PCM until it finishes committing AAC.
        // Keep the interprocess lock alive even if the session is released
        // immediately after pause; otherwise a new session can recover the
        // same PCM while the previous encoder is still writing it. Drain on
        // another queue because a completion callback may release the last
        // session reference from the encoder queue itself.
        let pendingJournal = journal, fd = lockFD
        DispatchQueue.global(qos: .utility).async {
            pendingJournal.waitForCompression()
            flock(fd, LOCK_UN); close(fd)
        }
    }

    static func inspect(directory: URL) throws -> Recovery {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        let scan = try ResilientRecordingJournal.scan(directory: directory)
        return Recovery(id: manifest.id, storedState: manifest.state,
                        frames: scan.chunks.reduce(0) { $0 + $1.frames }, unreadableIndices: scan.unreadableIndices,
                        quarantinedTail: manifest.quarantinedTail ?? [])
    }

    /// Bind one stream while paused. Hints may be missed or repeated; always
    /// enumerate sealedAACChunks on activation/restart. The callback must not
    /// block or call back into this session on the encoder queue.
    func configureSealedOutput(streamID: String, streamStartFrame: Int64 = 0,
                               onChunkSealed: @escaping (ResilientRecordingSegmentDescriptor) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !captureAuthorized, manifest.state != .finished, streamStartFrame >= 0,
              !streamID.isEmpty, streamID.utf8.count <= 48,
              streamID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
        else { throw CocoaError(.fileWriteUnknown) }
        journal.waitForCompression()
        try journal.checkEncoderFailure()
        let chunks = try ResilientRecordingJournal.recover(directory: directory)
        var cursor = streamStartFrame
        for chunk in chunks {
            guard chunk.frames <= Int64.max - cursor else { throw CocoaError(.fileReadCorruptFile) }
            cursor += chunk.frames
        }
        let binding = StreamBinding(recordingID: manifest.id, streamID: streamID, startFrame: streamStartFrame)
        let url = directory.appendingPathComponent("stream.json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try JSONDecoder().decode(StreamBinding.self, from: Data(contentsOf: url)) == binding else { throw CocoaError(.fileWriteFileExists) }
        } else {
            try JSONEncoder().encode(binding).write(to: url, options: .atomic)
        }
        let file = try FileHandle(forWritingTo: url); try file.synchronize(); try file.close()
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try journal.recoverPendingPCM(chunks, recordingID: manifest.id, streamID: streamID,
                                      streamStartFrame: streamStartFrame, onChunkSealed: onChunkSealed)
        try journal.configureSealedOutput(recordingID: manifest.id, streamID: streamID, nextFrame: cursor, onChunkSealed: onChunkSealed)
    }

    /// Recovery-time snapshot only. PCM tails remain visible to recovery, but
    /// are not advertised as sealed AAC. Callers must commit their own durable
    /// manifest before sending any descriptor to another device.
    func sealedAACChunks(streamID: String, streamStartFrame: Int64 = 0) throws -> [ResilientRecordingSegmentDescriptor] {
        lock.lock(); defer { lock.unlock() }
        guard streamStartFrame >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let bindingURL = directory.appendingPathComponent("stream.json")
        if FileManager.default.fileExists(atPath: bindingURL.path) {
            let binding = try JSONDecoder().decode(StreamBinding.self, from: Data(contentsOf: bindingURL))
            guard binding == StreamBinding(recordingID: manifest.id, streamID: streamID, startFrame: streamStartFrame)
            else { throw CocoaError(.fileReadCorruptFile) }
        }
        journal.waitForCompression()
        let chunks = try ResilientRecordingJournal.recover(directory: directory)
        var cursor = streamStartFrame
        var result: [ResilientRecordingSegmentDescriptor] = []
        for chunk in chunks {
            guard chunk.frames <= Int64.max - cursor else { throw CocoaError(.fileReadCorruptFile) }
            if chunk.url.pathExtension.lowercased() == "m4a" {
                let descriptor: ResilientRecordingSegmentDescriptor = try autoreleasepool {
                    let item = try ResilientRecordingJournal.describeSealedAAC(chunk, recordingID: manifest.id,
                                                                               streamID: streamID, startFrame: cursor)
                    try ResilientRecordingJournal.persistDescriptor(item, directory: directory)
                    return item
                }
                result.append(descriptor)
            }
            cursor += chunk.frames
        }
        return result
    }

    /// An explicit user decision may set aside an unreadable trailing chunk so
    /// earlier readable audio can be continued or finished. Original bytes are
    /// moved, never deleted. Damage in the middle is not silently skipped.
    func quarantineUnreadableTail() throws {
        lock.lock(); defer { lock.unlock() }
        guard !captureAuthorized, manifest.state != .finished else { throw CocoaError(.fileWriteUnknown) }
        journal.waitForCompression()
        let scan = try ResilientRecordingJournal.scan(directory: directory)
        guard !scan.unreadableIndices.isEmpty,
              scan.unreadableIndices.allSatisfy({ $0 > (scan.chunks.last?.index ?? -1) })
        else { throw CocoaError(.fileReadCorruptFile) }
        var next = manifest
        next.quarantinedTail = Array(Set((next.quarantinedTail ?? []) + scan.unreadableIndices)).sorted()
        // Record the warning before moving anything; a crash cannot hide it.
        try Self.save(next, to: manifestURL); manifest = next
        let preserved = directory.appendingPathComponent("unreadable", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true)
        for index in scan.unreadableIndices {
            for ext in ["caf", "m4a"] {
                let name = String(format: "%08d.%@", index, ext)
                let source = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.moveItem(at: source, to: preserved.appendingPathComponent(name))
                }
            }
        }
        journal = try ResilientRecordingJournal(directory: directory, encodeChunk: encodeChunkOverride)
    }

    /// Call only after the user asks to record and audio permissions are granted.
    func startOrResume() throws {
        lock.lock(); defer { lock.unlock() }
        guard manifest.state != .finished, !captureAuthorized else { throw CocoaError(.fileWriteUnknown) }
        journal.waitForCompression()
        try journal.checkEncoderFailure()
        let scan = try ResilientRecordingJournal.scan(directory: directory)
        guard scan.unreadableIndices.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var next = manifest; next.state = .active
        try Self.save(next, to: manifestURL); manifest = next; captureAuthorized = true
    }
    func append(_ buffer: AVAudioPCMBuffer, allowingBackloggedPCM: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard manifest.state == .active, captureAuthorized else { throw CocoaError(.fileWriteUnknown) }
        try journal.append(buffer, allowingBackloggedPCM: allowingBackloggedPCM)
    }
    func checkEncoderFailure() throws {
        lock.lock(); defer { lock.unlock() }
        try journal.checkEncoderFailure()
    }
    func pause() throws {
        lock.lock(); defer { lock.unlock() }
        guard manifest.state == .active else { return }
        journal.checkpoint(); captureAuthorized = false
        var next = manifest; next.state = .paused
        try Self.save(next, to: manifestURL); manifest = next
    }
    /// Finalize a single stream as the canonical segment set; no AAC is
    /// decoded and re-encoded. Multi-stream recordings need a coordinator to
    /// combine their verified stream manifests on the common timeline.
    func finishSegments() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard manifest.state != .finished else { throw CocoaError(.fileWriteFileExists) }
        captureAuthorized = false; journal.checkpoint(); journal.waitForCompression()
        try journal.checkEncoderFailure()
        let binding = try JSONDecoder().decode(StreamBinding.self, from: Data(contentsOf: directory.appendingPathComponent("stream.json")))
        guard binding.recordingID == manifest.id else { throw CocoaError(.fileReadCorruptFile) }
        let chunks = try ResilientRecordingJournal.recover(directory: directory)
        guard !chunks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var cursor = binding.startFrame, segments: [FinalSegment] = []
        for (index, chunk) in chunks.enumerated() {
            guard chunk.index == index, chunk.url.pathExtension.lowercased() == "m4a",
                  chunk.frames <= Int64.max - cursor else { throw CocoaError(.fileReadCorruptFile) }
            let item: ResilientRecordingSegmentDescriptor = try autoreleasepool {
                let descriptor = try ResilientRecordingJournal.describeSealedAAC(chunk, recordingID: manifest.id,
                                                                                  streamID: binding.streamID, startFrame: cursor)
                try ResilientRecordingJournal.persistDescriptor(descriptor, directory: directory)
                return descriptor
            }
            segments.append(FinalSegment(item)); cursor += chunk.frames
        }
        let final = FinalManifest(recordingID: manifest.id,
                                  streams: [FinalStream(streamID: binding.streamID, startFrame: binding.startFrame, segments: segments)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(final)
        let url = directory.appendingPathComponent("final.manifest.json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { throw CocoaError(.fileWriteFileExists) }
        } else { try data.write(to: url, options: .atomic) }
        let file = try FileHandle(forWritingTo: url); try file.synchronize(); try file.close()
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var next = manifest; next.state = .finished; next.outputName = url.lastPathComponent
        try Self.save(next, to: manifestURL); manifest = next
        return url
    }
    /// The caller supplies a new output path. Existing outputs and all source
    /// chunks are kept, including if assembly or the final manifest write fails.
    func finish(destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard manifest.state != .finished else { throw CocoaError(.fileWriteFileExists) }
        captureAuthorized = false; journal.checkpoint(); journal.waitForCompression()
        try journal.checkEncoderFailure()
        let chunks = try ResilientRecordingJournal.recover(directory: directory)
        try ResilientRecordingJournal.assemble(chunks, destination: destination)
        var next = manifest; next.state = .finished; next.outputName = destination.lastPathComponent
        try Self.save(next, to: manifestURL); manifest = next
    }
    private static func save(_ manifest: Manifest, to url: URL) throws {
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url); try file.synchronize(); try file.close()
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let committed = fsync(fd) == 0; close(fd)
        guard committed else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Serializes conversion and disk writes away from the audio callback. The
/// caller stops its input before requesting pause or finish, and must surface
/// any thrown/backpressure or asynchronous failure instead of dropping audio.
final class ResilientRecordingPipeline {
    enum PipelineError: Error { case notRecording, backlogExceeded, invalidBuffer }
    private enum State { case paused, recording, draining, failed, finished }
    private let source: AVAudioFormat
    private let session: ResilientRecordingSession
    private let onFailure: (Error) -> Void
    private let queue = DispatchQueue(label: "talktuck.recording.pipeline")
    private let lock = NSLock()
    private var state: State = .paused
    private var converter: ResilientRecordingConverter?
    private var pendingFrames: Int64 = 0
    private let maximumPendingFrames: Int64

    init(session: ResilientRecordingSession, source: AVAudioFormat, onFailure: @escaping (Error) -> Void) throws {
        guard source.sampleRate.isFinite, source.sampleRate > 0, source.sampleRate <= 384_000,
              source.channelCount > 0 else { throw PipelineError.invalidBuffer }
        self.session = session; self.source = source; self.onFailure = onFailure
        maximumPendingFrames = max(1, Int64(source.sampleRate * 2))
    }
    func startOrResume() throws {
        lock.lock(); defer { lock.unlock() }
        guard state == .paused else { throw PipelineError.notRecording }
        let next = try ResilientRecordingConverter(source: source)
        try session.startOrResume()
        converter = next; state = .recording
    }
    func submit(_ input: AVAudioPCMBuffer) throws {
        guard input.format == source, input.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: input.frameLength) else { throw PipelineError.invalidBuffer }
        copy.frameLength = input.frameLength
        let from = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { throw PipelineError.invalidBuffer }
        for index in 0..<from.count {
            guard let sourceData = from[index].mData, let targetData = to[index].mData,
                  from[index].mDataByteSize <= to[index].mDataByteSize else { throw PipelineError.invalidBuffer }
            memcpy(targetData, sourceData, Int(from[index].mDataByteSize))
        }
        let frames = Int64(input.frameLength)
        lock.lock()
        guard state == .recording else { lock.unlock(); throw PipelineError.notRecording }
        guard pendingFrames + frames <= maximumPendingFrames else {
            // A rejected buffer is missing audio: stop the pipeline rather than
            // allowing a caller to accidentally continue with an unnoticed gap.
            // Drain already accepted buffers before sealing; they must not be
            // discarded merely because a later buffer overflowed the queue.
            state = .draining
            queue.async { [self] in
                lock.lock(); let previouslyFailed = state == .failed; lock.unlock()
                guard !previouslyFailed else { return }
                do {
                    if let converter {
                        for buffer in try converter.finish() { try session.append(buffer, allowingBackloggedPCM: true) }
                        self.converter = nil
                    }
                    try session.pause()
                    fail(PipelineError.backlogExceeded)
                } catch { fail(error) }
            }
            lock.unlock()
            throw PipelineError.backlogExceeded
        }
        pendingFrames += frames
        // Enqueue while holding the lock so pause/finish cannot overtake this buffer.
        queue.async { [self] in
            defer { lock.lock(); pendingFrames -= frames; lock.unlock() }
            lock.lock(); let usable = state != .failed; lock.unlock()
            guard usable else { return }
            do {
                guard let converter else { throw PipelineError.notRecording }
                for buffer in try converter.convert(copy) { try session.append(buffer, allowingBackloggedPCM: true) }
                lock.lock(); let recording = state == .recording; lock.unlock()
                if recording {
                    do { try session.checkEncoderFailure() }
                    catch ResilientRecordingJournal.JournalError.encoderBacklogExceeded { stopAfterEncoderBacklog() }
                }
            } catch { fail(error) }
        }
        lock.unlock()
    }
    func pause(completion: @escaping (Result<Void, Error>) -> Void) {
        drain(destination: nil, completion: completion)
    }
    /// Stop accepting new input, but preserve all buffers accepted before the
    /// encoder backlog was noticed. The terminal notification follows the drain.
    private func stopAfterEncoderBacklog() {
        lock.lock()
        guard state == .recording else { lock.unlock(); return }
        state = .draining
        queue.async { [self] in
            lock.lock(); let failed = state == .failed; lock.unlock()
            guard !failed else { return }
            do {
                if let converter {
                    for buffer in try converter.finish() { try session.append(buffer, allowingBackloggedPCM: true) }
                    self.converter = nil
                }
                try session.pause()
                fail(ResilientRecordingJournal.JournalError.encoderBacklogExceeded)
            } catch { fail(error) }
        }
        lock.unlock()
    }
    func finish(destination: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        drain(destination: destination, completion: completion)
    }
    /// Drain already accepted buffers and finalize the canonical segment set.
    /// Input must have stopped before this call, as with pause/finish.
    func finishSegments(completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock()
        guard state == .recording || state == .paused else {
            lock.unlock(); completion(.failure(PipelineError.notRecording)); return
        }
        state = .draining
        queue.async { [self] in
            lock.lock(); let failed = state == .failed; lock.unlock()
            guard !failed else { completion(.failure(PipelineError.notRecording)); return }
            do {
                if let converter {
                    for buffer in try converter.finish() { try session.append(buffer, allowingBackloggedPCM: true) }
                    self.converter = nil
                }
                let url = try session.finishSegments()
                lock.lock(); state = .finished; lock.unlock()
                completion(.success(url))
            } catch { fail(error); completion(.failure(error)) }
        }
        lock.unlock()
    }
    private func drain(destination: URL?, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        guard state == .recording || (state == .paused && destination != nil) else {
            lock.unlock(); completion(.failure(PipelineError.notRecording)); return
        }
        state = .draining
        queue.async { [self] in
            lock.lock(); let failed = state == .failed; lock.unlock()
            guard !failed else { completion(.failure(PipelineError.notRecording)); return }
            do {
                if let converter {
                    for buffer in try converter.finish() { try session.append(buffer, allowingBackloggedPCM: true) }
                    self.converter = nil
                }
                if let destination { try session.finish(destination: destination) }
                else { try session.pause(); try session.checkEncoderFailure() }
                lock.lock(); state = destination == nil ? .paused : .finished; lock.unlock()
                completion(.success(()))
            } catch { fail(error); completion(.failure(error)) }
        }
        lock.unlock()
    }
    private func fail(_ error: Error) {
        lock.lock(); let shouldNotify = state != .failed; state = .failed; lock.unlock()
        if shouldNotify { onFailure(error) }
    }
}
