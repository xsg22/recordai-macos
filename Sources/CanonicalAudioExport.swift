import Foundation
import AVFoundation
import Darwin
import CryptoKit

/// Explicit single-file compatibility export. The canonical AAC segments and
/// manifest are never modified. Call from a cancellable background task.
enum CanonicalAudioExport {
    enum Failure: Error { case unsupportedStreams, corruptCache, invalidArchive }
    private struct CacheEntry: Codable {
        let manifestSHA256: String
        let audioSHA256: String
        let bytes: Int64
        let frames: Int64
        let filename: String
    }
    private static let condition = NSCondition()
    private static var running = Set<String>()
    static func defaultCacheRoot() throws -> URL {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { throw Failure.invalidArchive }
        return root.appendingPathComponent("TalkTuckAudioExports", isDirectory: true)
    }

    static func prepare(manifestURL: URL, recordingID: UUID, cacheRoot: URL,
                        isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> URL {
        func checkCancellation() throws { if isCancelled() { throw CancellationError() } }
        func hashFile(_ url: URL) throws -> (Int64, String) {
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            var hash = SHA256(), count: Int64 = 0
            while true {
                try checkCancellation()
                let more: Bool = try autoreleasepool {
                    guard let data = try input.read(upToCount: 65_536), !data.isEmpty else { return false }
                    count += Int64(data.count); hash.update(data: data); return true
                }
                if !more { break }
            }
            return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        guard manifestURL.lastPathComponent == "final.manifest.json" else { throw Failure.invalidArchive }
        let info = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard let length = info[.size] as? NSNumber, length.int64Value > 0, length.int64Value <= 16 * 1024 * 1024 else { throw Failure.invalidArchive }
        let manifest = try JSONDecoder().decode(BalancedRecordingManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        guard manifest.recordingID == recordingID else { throw Failure.invalidArchive }
        // A cached derivative must never hide a missing or damaged original.
        let archiveRoot = manifestURL.deletingLastPathComponent()
        for stream in manifest.streams {
            for segment in stream.segments {
                try checkCancellation()
                let source = archiveRoot.appendingPathComponent(stream.streamID).appendingPathComponent(segment.filename)
                guard source.standardizedFileURL.resolvingSymlinksInPath() == source.standardizedFileURL else { throw Failure.invalidArchive }
                try BalancedAudioIO.validateFile(source,segment:segment,decode:false)
            }
        }
        let key = try manifest.digest()
        let frames = manifest.durationFrames
        guard frames > 0 else { throw Failure.invalidArchive }
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let pointer = cacheRoot.appendingPathComponent(key + ".json")

        let lockKey = cacheRoot.standardizedFileURL.path + ":" + key
        condition.lock()
        while running.contains(lockKey) {
            if isCancelled() { condition.unlock(); throw CancellationError() }
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
        }
        running.insert(lockKey); condition.unlock()
        defer { condition.lock(); running.remove(lockKey); condition.broadcast(); condition.unlock() }
        try checkCancellation()
        if FileManager.default.fileExists(atPath: pointer.path) {
          do {
            let entry = try JSONDecoder().decode(CacheEntry.self, from: Data(contentsOf: pointer))
            guard entry.manifestSHA256 == key, entry.frames == frames,
                  BalancedAudioSegment.validHash(entry.audioSHA256),
                  entry.filename == key + "-" + entry.audioSHA256 + ".m4a" else { throw Failure.corruptCache }
            let existing = cacheRoot.appendingPathComponent(entry.filename)
            if FileManager.default.fileExists(atPath: existing.path) {
                let (bytes, hash) = try hashFile(existing)
                let audio = try AVAudioFile(forReading: existing)
                guard bytes == entry.bytes, hash == entry.audioSHA256, audio.length == frames,
                      audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
                      audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1 else { throw Failure.corruptCache }
                try checkCancellation(); progress(1); return existing
            }
            // iOS may evict a cached output independently of its pointer.
            try FileManager.default.removeItem(at: pointer)
          } catch is CancellationError { throw CancellationError() }
          catch {
            // Only discard our derived receipt, never the source archive.
            // A damaged or interrupted cache can be regenerated on retry.
            try FileManager.default.removeItem(at:pointer)
          }
        }

        let stage = cacheRoot.appendingPathComponent(".partial-" + UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: stage) }
        var written: Int64 = 0
        let reader = try CanonicalAudioReader(manifestURL: manifestURL)
        try autoreleasepool {
            let output = try AVAudioFile(forWriting: stage, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            while written < frames {
                try checkCancellation()
                try autoreleasepool {
                    let buffer = try reader.read(startFrame: written, count: 4096)
                    guard buffer.frameLength > 0 else { throw Failure.invalidArchive }
                    try output.write(from: buffer); written += Int64(buffer.frameLength)
                }
                progress(0.9 * Double(written) / Double(frames))
            }
        }
        try checkCancellation()
        guard written == frames else { throw Failure.invalidArchive }
        try autoreleasepool {
            let audio = try AVAudioFile(forReading: stage)
            guard audio.length == frames, audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
                  audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { throw Failure.invalidArchive }
            var decoded: Int64 = 0
            while audio.framePosition < audio.length {
                try checkCancellation(); try audio.read(into: buffer)
                guard buffer.frameLength > 0 else { throw Failure.invalidArchive }
                decoded += Int64(buffer.frameLength)
            }
            guard decoded == frames else { throw Failure.invalidArchive }
        }
        let file = try FileHandle(forWritingTo: stage); try file.synchronize(); try file.close()
        let (bytes, audioHash) = try hashFile(stage)
        try checkCancellation()
        let filename = key + "-" + audioHash + ".m4a", destination = cacheRoot.appendingPathComponent(filename)
        var createdDestination = false, committed = false
        defer { if createdDestination && !committed { try? FileManager.default.removeItem(at: destination) } }
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try hashFile(destination)
            if existing.0 != bytes || existing.1 != audioHash {
                try FileManager.default.removeItem(at:destination)
                try FileManager.default.moveItem(at:stage,to:destination); createdDestination = true
            }
        } else { try FileManager.default.moveItem(at: stage, to: destination); createdDestination = true }
        try BalancedAudioIO.syncDirectory(cacheRoot)
        try checkCancellation()
        let entry = CacheEntry(manifestSHA256: key, audioSHA256: audioHash, bytes: bytes, frames: frames, filename: filename)
        try BalancedAudioIO.save(entry, to: pointer)
        committed = true
        progress(1); return destination
    }
}
