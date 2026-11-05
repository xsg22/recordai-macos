import Foundation
import AVFoundation
import CryptoKit
import Darwin

enum BalancedAudioError: Error {
    case invalidDescriptor, invalidManifest, identityConflict, integrityFailure
}

/// The URL is deliberately absent: a sender cannot choose paths on the receiver.
struct BalancedAudioSegment: Codable, Equatable, Sendable {
    static let formatID = "talktuck.aac16k.v1"
    static let maximumTimelineFrames = Int64(Int32.max) * 16
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

    var key: String { recordingID.uuidString + "/" + streamID + "/" + String(index) }
    var filename: String { String(format: "%08d.m4a", index) }
    var endFrame: Int64 { startFrame + validFrames }
    var isValid: Bool {
        Self.validStream(streamID) && index >= 0 && index < 100_000 &&
        startFrame >= 0 && startFrame <= Self.maximumTimelineFrames - 160_000 &&
        validFrames > 0 && validFrames <= 160_000 && sampleRate == 16_000 && channels == 1 &&
        bitRate == 32_000 && byteCount > 0 && byteCount <= 256 * 1024 && Self.validHash(sha256)
    }
    static func validStream(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 48 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    init(recordingID: UUID, streamID: String, index: Int, startFrame: Int64, validFrames: Int64,
         sampleRate: Int = 16_000, channels: Int = 1, bitRate: Int = 32_000, byteCount: Int64, sha256: String) {
        self.recordingID = recordingID; self.streamID = streamID; self.index = index
        self.startFrame = startFrame; self.validFrames = validFrames; self.sampleRate = sampleRate
        self.channels = channels; self.bitRate = bitRate; self.byteCount = byteCount; self.sha256 = sha256
    }
}

struct BalancedAudioStream: Codable, Equatable, Sendable {
    let streamID: String
    let startFrame: Int64
    let segments: [BalancedAudioSegment]
    var endFrame: Int64 { segments.last?.endFrame ?? startFrame }
}

struct BalancedRecordingManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let formatID: String
    let recordingID: UUID
    let streams: [BalancedAudioStream]

    init(recordingID: UUID, streams: [BalancedAudioStream]) {
        schemaVersion = 1; formatID = BalancedAudioSegment.formatID
        self.recordingID = recordingID; self.streams = streams.sorted { $0.streamID < $1.streamID }
    }
    func validate() throws {
        guard schemaVersion == 1, formatID == BalancedAudioSegment.formatID,
              !streams.isEmpty, streams.count <= 8,
              segmentCount <= 100_000,
              Set(streams.map(\.streamID)).count == streams.count,
              streams.map(\.streamID) == streams.map(\.streamID).sorted() else { throw BalancedAudioError.invalidManifest }
        for stream in streams {
            guard BalancedAudioSegment.validStream(stream.streamID), stream.startFrame >= 0,
                  !stream.segments.isEmpty, stream.segments.count <= 100_000 else { throw BalancedAudioError.invalidManifest }
            var cursor = stream.startFrame
            for (index, segment) in stream.segments.enumerated() {
                guard segment.isValid, segment.recordingID == recordingID, segment.streamID == stream.streamID,
                      segment.index == index, segment.startFrame == cursor else { throw BalancedAudioError.invalidManifest }
                cursor = segment.endFrame
            }
        }
    }
    var segmentCount: Int { streams.reduce(0) { $0 + $1.segments.count } }
    var byteCount: Int64 { streams.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.byteCount } } }
    var durationFrames: Int64 { streams.map(\.endFrame).max() ?? 0 }
    func canonicalData() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    func digest() throws -> String { BalancedAudioIO.hash(try canonicalData()) }
}

struct BalancedSegmentReceipt: Codable, Equatable, Sendable {
    let segment: BalancedAudioSegment
}
struct BalancedRecordingReceipt: Codable, Equatable, Sendable {
    let recordingID: UUID
    let manifestSHA256: String
    let segmentCount: Int
    let byteCount: Int64
    let durationFrames: Int64
}
struct BalancedPlaybackStreamHead: Codable, Equatable, Sendable {
    let streamID: String
    let startFrame: Int64
    var endFrame: Int64
    var segmentCount: Int
    var byteCount: Int64
}
struct BalancedPlaybackHead: Codable, Equatable, Sendable {
    let kind: String
    let schemaVersion: Int
    let formatID: String
    let recordingID: UUID
    var streams: [BalancedPlaybackStreamHead]
    init(recordingID: UUID, streams: [BalancedPlaybackStreamHead] = []) {
        kind = "live-prefix"; schemaVersion = 1; formatID = BalancedAudioSegment.formatID
        self.recordingID = recordingID; self.streams = streams.sorted { $0.streamID < $1.streamID }
    }
    var durationFrames: Int64 { streams.map(\.endFrame).max() ?? 0 }
    func validate() throws {
        guard kind == "live-prefix", schemaVersion == 1, formatID == BalancedAudioSegment.formatID,
              !streams.isEmpty, streams.count <= 8, Set(streams.map(\.streamID)).count == streams.count,
              streams.allSatisfy({ BalancedAudioSegment.validStream($0.streamID) && $0.startFrame >= 0 &&
                  $0.endFrame > $0.startFrame && $0.endFrame <= BalancedAudioSegment.maximumTimelineFrames &&
                  $0.segmentCount > 0 && $0.segmentCount <= 100_000 && $0.byteCount > 0 })
        else { throw BalancedAudioError.invalidManifest }
    }
}
struct BalancedMissingRange: Codable, Equatable, Sendable {
    let streamID: String
    let firstIndex: Int
    let lastIndex: Int
}
struct BalancedReceiveResult: Sendable {
    let missing: [BalancedMissingRange]
    let receipt: BalancedRecordingReceipt?
    var moreMissingRanges = false
}

enum BalancedAudioIO {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hashFile(_ url: URL, maximumBytes: Int64 = 256 * 1024) throws -> (Int64, String) {
        // FileHandle bridges autoreleased NSData. A single verification job may
        // visit thousands of assets; its pool must drain per file, not per job.
        try autoreleasepool {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var digest = SHA256(), bytes: Int64 = 0
        while let data = try input.read(upToCount: 65_536), !data.isEmpty {
            bytes += Int64(data.count)
            guard bytes <= maximumBytes else { throw BalancedAudioError.integrityFailure }
            digest.update(data: data)
        }
        return (bytes, digest.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
    static func validateFile(_ url: URL, segment: BalancedAudioSegment, decode: Bool = true) throws {
        try autoreleasepool {
        guard segment.isValid else { throw BalancedAudioError.invalidDescriptor }
        let (bytes, digest) = try hashFile(url)
        guard bytes == segment.byteCount, digest == segment.sha256 else { throw BalancedAudioError.integrityFailure }
        if decode {
            let audio = try AVAudioFile(forReading: url)
            guard audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
                  audio.length == segment.validFrames, audio.processingFormat.sampleRate == 16_000,
                  audio.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)
            else { throw BalancedAudioError.integrityFailure }
            var frames: Int64 = 0
            while audio.framePosition < audio.length {
                try audio.read(into: buffer)
                guard buffer.frameLength > 0 else { throw BalancedAudioError.integrityFailure }
                frames += Int64(buffer.frameLength)
            }
            guard frames == segment.validFrames else { throw BalancedAudioError.integrityFailure }
        }
        }
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.synchronize(); try syncDirectory(url.deletingLastPathComponent())
    }
}

/// Durable receiver independent of UI, ASR and transport. Call from a serialized
/// worker. Only a successful library commit is allowed to produce a final receipt.
final class BalancedAudioInbox: @unchecked Sendable {
    let root: URL
    private let lock = NSRecursiveLock()
    init(root: URL) { self.root = root }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func fileURL(_ segment: BalancedAudioSegment) -> URL {
        directory(segment.recordingID).appendingPathComponent(segment.streamID, isDirectory: true).appendingPathComponent(segment.filename)
    }
    /// Transport offsets are resumable progress, not durable audio ACKs.
    /// Only the existing receive transaction can acknowledge a complete AAC.
    func receiveMessagePart(payload: Data, segment: BalancedAudioSegment, offset: Int) throws -> (nextOffset: Int, receipt: BalancedSegmentReceipt?) {
        lock.lock(); defer { lock.unlock() }
        guard segment.isValid, segment.byteCount <= 131_072, !payload.isEmpty, payload.count <= 32_768,
              offset >= 0, Int64(offset) <= segment.byteCount,
              Int64(payload.count) <= segment.byteCount - Int64(offset) else { throw BalancedAudioError.invalidDescriptor }
        let target = fileURL(segment)
        if FileManager.default.fileExists(atPath: target.path) {
            return (Int(segment.byteCount), try receive(target, segment: segment))
        }
        let folder = directory(segment.recordingID).appendingPathComponent(".message-parts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(segment.streamID + "-" + String(segment.index) + "-" + segment.sha256 + ".partial")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard (try FileManager.default.contentsOfDirectory(atPath: folder.path)).count < 64 else { throw BalancedAudioError.invalidDescriptor }
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= segment.byteCount else { throw BalancedAudioError.integrityFailure }
        guard offset <= size else { return (size, nil) }
        let handle = try FileHandle(forUpdating: file); defer { try? handle.close() }
        let overlap = min(payload.count, size - offset)
        if overlap > 0 {
            try handle.seek(toOffset: UInt64(offset))
            guard try handle.read(upToCount: overlap) == payload.prefix(overlap) else { throw BalancedAudioError.integrityFailure }
        }
        if overlap < payload.count {
            try handle.seek(toOffset: UInt64(size)); try handle.write(contentsOf: payload.dropFirst(overlap))
        }
        let ending = max(size, offset + payload.count)
        guard ending == Int(segment.byteCount) else { return (ending, nil) }
        try handle.synchronize()
        let receipt = try receive(file, segment: segment)
        try? FileManager.default.removeItem(at: file)
        return (ending, receipt)
    }
    private func descriptorURL(_ segment: BalancedAudioSegment) -> URL { fileURL(segment).deletingPathExtension().appendingPathExtension("json") }
    private func advancePlaybackHead(_ segment: BalancedAudioSegment) throws {
        let file = directory(segment.recordingID).appendingPathComponent("playback.manifest.json")
        var head: BalancedPlaybackHead
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 16_384 else { throw BalancedAudioError.invalidManifest }
            head = try JSONDecoder().decode(BalancedPlaybackHead.self, from: data)
            try head.validate(); guard head.recordingID == segment.recordingID else { throw BalancedAudioError.identityConflict }
        } else { head = BalancedPlaybackHead(recordingID: segment.recordingID) }
        var stream = head.streams.first { $0.streamID == segment.streamID }
        if stream == nil {
            guard segment.index == 0 else { return }
            stream = BalancedPlaybackStreamHead(streamID: segment.streamID, startFrame: segment.startFrame,
                endFrame: segment.startFrame, segmentCount: 0, byteCount: 0)
        }
        var value = stream!
        let oldCount = value.segmentCount
        while value.segmentCount < 100_000 {
            let nextURL = fileURL(segment).deletingLastPathComponent().appendingPathComponent(String(format: "%08d.json", value.segmentCount))
            guard FileManager.default.fileExists(atPath: nextURL.path) else { break }
            let next: BalancedAudioSegment = try autoreleasepool {
                try JSONDecoder().decode(BalancedAudioSegment.self, from: Data(contentsOf: nextURL))
            }
            guard next.isValid, next.recordingID == segment.recordingID, next.streamID == value.streamID,
                  next.index == value.segmentCount, next.startFrame == value.endFrame else { throw BalancedAudioError.identityConflict }
            let size = (try FileManager.default.attributesOfItem(atPath: fileURL(next).path)[.size] as? NSNumber)?.int64Value
            guard size == next.byteCount else { break }
            value.segmentCount += 1; value.endFrame = next.endFrame; value.byteCount += next.byteCount
        }
        guard value.segmentCount > oldCount else { return }
        head.streams.removeAll { $0.streamID == value.streamID }; head.streams.append(value)
        head.streams.sort { $0.streamID < $1.streamID }; try head.validate()
        try BalancedAudioIO.save(head, to: file)
    }
    func playbackHead(_ id: UUID) throws -> BalancedPlaybackHead? {
        lock.lock(); defer { lock.unlock() }
        let folder = directory(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        // Repair a crash between sidecar commit and tiny-head commit. Ordinarily
        // this reads only the first descriptor and the next absent index per stream.
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where BalancedAudioSegment.validStream(name) {
            let first = folder.appendingPathComponent(name).appendingPathComponent("00000000.json")
            if let data = try? Data(contentsOf: first), let segment = try? JSONDecoder().decode(BalancedAudioSegment.self, from: data),
               segment.isValid, segment.recordingID == id, segment.streamID == name { try advancePlaybackHead(segment) }
        }
        let url = folder.appendingPathComponent("playback.manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 16_384 else { throw BalancedAudioError.invalidManifest }
        let head = try JSONDecoder().decode(BalancedPlaybackHead.self, from: data)
        try head.validate(); return head
    }

    func receive(_ source: URL, segment: BalancedAudioSegment) throws -> BalancedSegmentReceipt {
        lock.lock(); defer { lock.unlock() }
        guard segment.isValid else { throw BalancedAudioError.invalidDescriptor }
        let manager = FileManager.default, target = fileURL(segment), metadata = descriptorURL(segment)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: metadata.path) {
            if let old = try? JSONDecoder().decode(BalancedAudioSegment.self, from: Data(contentsOf: metadata)) {
                guard old == segment else { throw BalancedAudioError.identityConflict }
            } else {
                try manager.moveItem(at: metadata, to: metadata.appendingPathExtension("damaged-" + UUID().uuidString))
            }
        }
        if FileManager.default.fileExists(atPath: target.path),
           let old = try? JSONDecoder().decode(BalancedAudioSegment.self, from: Data(contentsOf: metadata)), old != segment {
                throw BalancedAudioError.identityConflict
        }
        if (try? BalancedAudioIO.validateFile(target, segment: segment, decode: false)) != nil {
            // Validate the source too: an identity collision cannot obtain an ACK
            // merely because a valid older file is already on disk.
            try BalancedAudioIO.validateFile(source, segment: segment)
            try BalancedAudioIO.save(segment, to: metadata)
            try advancePlaybackHead(segment)
            return BalancedSegmentReceipt(segment: segment)
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".receive-" + UUID().uuidString + ".m4a")
        defer { try? manager.removeItem(at: temporary) }
        try manager.copyItem(at: source, to: temporary)
        try BalancedAudioIO.validateFile(temporary, segment: segment)
        let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
        if manager.fileExists(atPath: target.path) {
            let damaged = target.appendingPathExtension("damaged-" + UUID().uuidString)
            try manager.moveItem(at: target, to: damaged)
        }
        try manager.moveItem(at: temporary, to: target)
        try BalancedAudioIO.syncDirectory(target.deletingLastPathComponent())
        try BalancedAudioIO.save(segment, to: metadata)
        try advancePlaybackHead(segment)
        return BalancedSegmentReceipt(segment: segment)
    }

    func receive(_ manifest: BalancedRecordingManifest,
                 commitLibrary: (BalancedRecordingManifest, URL) throws -> Void) throws -> BalancedReceiveResult {
        lock.lock(); defer { lock.unlock() }
        try manifest.validate()
        let folder = directory(manifest.recordingID), manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("final.manifest.json")
        if manager.fileExists(atPath: url.path) {
            guard try JSONDecoder().decode(BalancedRecordingManifest.self, from: Data(contentsOf: url)) == manifest else {
                throw BalancedAudioError.identityConflict
            }
        }
        try BalancedAudioIO.save(manifest, to: url)
        var missing: [BalancedMissingRange] = []
        for stream in manifest.streams {
            var start: Int?, last = -1
            for segment in stream.segments {
                let metadata = try? JSONDecoder().decode(BalancedAudioSegment.self, from: Data(contentsOf: descriptorURL(segment)))
                let valid = metadata == segment && (try? BalancedAudioIO.validateFile(fileURL(segment), segment: segment, decode: false)) != nil
                if valid {
                    if let begin = start { missing.append(BalancedMissingRange(streamID: stream.streamID, firstIndex: begin, lastIndex: last)); start = nil }
                } else { if start == nil { start = segment.index }; last = segment.index }
            }
            if let begin = start { missing.append(BalancedMissingRange(streamID: stream.streamID, firstIndex: begin, lastIndex: last)) }
        }
        guard missing.isEmpty else {
            let verified = folder.appendingPathComponent("verified.json")
            if manager.fileExists(atPath: verified.path) {
                try manager.moveItem(at: verified, to: verified.appendingPathExtension("invalidated-" + UUID().uuidString))
                try BalancedAudioIO.syncDirectory(folder)
            }
            return BalancedReceiveResult(missing: Array(missing.prefix(64)), receipt: nil, moreMissingRanges: missing.count > 64)
        }
        try commitLibrary(manifest, url)
        let receipt = BalancedRecordingReceipt(recordingID: manifest.recordingID, manifestSHA256: try manifest.digest(),
            segmentCount: manifest.segmentCount, byteCount: manifest.byteCount, durationFrames: manifest.durationFrames)
        try BalancedAudioIO.save(receipt, to: folder.appendingPathComponent("verified.json"))
        return BalancedReceiveResult(missing: [], receipt: receipt)
    }
}

/// Persisted sender inventory. Capturing is independent of network ACKs; only
/// exact content receipts remove segments from the pending delivery inventory.
final class BalancedAudioOutbox {
    private struct Entry: Codable {
        let segment: BalancedAudioSegment
        let path: String
        var confirmed: Bool
    }
    private struct FinalProof: Codable {
        let manifest: BalancedRecordingManifest
        let receipt: BalancedRecordingReceipt
    }
    private let root: URL
    private let sourceRoot: URL?
    private let lock = NSRecursiveLock()
    private var entries: [String: Entry] = [:]
    private var pendingKeys: [String] = []
    private var pendingHead = 0
    private var loaded = false
    init(root: URL, sourceRoot: URL? = nil) { self.root = root; self.sourceRoot = sourceRoot }
    private func sourceURL(_ segment: BalancedAudioSegment, storedPath: String) -> URL {
        guard let sourceRoot else { return URL(fileURLWithPath: storedPath) }
        // iOS/watchOS can relocate an app container during an update. Identity,
        // not a serialized sandbox UUID, determines the canonical source file.
        return sourceRoot.appendingPathComponent(segment.recordingID.uuidString)
            .appendingPathComponent(segment.streamID).appendingPathComponent(segment.filename)
    }
    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var recovered: [String: Entry] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var completed: [String: BalancedAudioSegment] = [:]
        for file in files where file.pathExtension == "receipt" {
            let proof = try JSONDecoder().decode(FinalProof.self, from: Data(contentsOf: file))
            guard proof.receipt == (try Self.finalReceipt(proof.manifest)) else { throw BalancedAudioError.identityConflict }
            for segment in proof.manifest.streams.flatMap(\.segments) { completed[segment.key] = segment }
        }
        for file in files where file.pathExtension == "json" {
            var entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
            guard entry.segment.isValid, recovered[entry.segment.key] == nil,
                  file.lastPathComponent == metadataURL(entry.segment).lastPathComponent,
                  recovered.count < 100_000 else { throw BalancedAudioError.identityConflict }
            recovered[entry.segment.key] = entry
            if let confirmed = completed[entry.segment.key] {
                guard confirmed == entry.segment else { throw BalancedAudioError.identityConflict }
                entry.confirmed = true; recovered[entry.segment.key] = entry
            }
        }
        entries = recovered
        pendingKeys = recovered.values.filter { !$0.confirmed }.sorted {
            if $0.segment.recordingID != $1.segment.recordingID { return $0.segment.recordingID.uuidString < $1.segment.recordingID.uuidString }
            if $0.segment.streamID != $1.segment.streamID { return $0.segment.streamID < $1.segment.streamID }
            return $0.segment.index < $1.segment.index
        }.map { $0.segment.key }
        pendingHead = 0
        loaded = true
    }
    private func metadataURL(_ segment: BalancedAudioSegment) -> URL {
        root.appendingPathComponent(segment.recordingID.uuidString + "-" + segment.streamID + "-" + String(segment.index) + ".json")
    }
    func enqueue(_ segment: BalancedAudioSegment, file: URL) throws {
        lock.lock(); defer { lock.unlock() }; try load()
        guard segment.isValid else { throw BalancedAudioError.invalidDescriptor }
        if let old = entries[segment.key] {
            guard old.segment == segment, sourceURL(old.segment, storedPath: old.path).standardizedFileURL.path == file.standardizedFileURL.path else { throw BalancedAudioError.identityConflict }
            return
        }
        guard entries.count < 100_000 else { throw BalancedAudioError.invalidDescriptor }
        try BalancedAudioIO.validateFile(file, segment: segment)
        let path: String
        if sourceRoot != nil {
            guard sourceURL(segment, storedPath: "").standardizedFileURL.path == file.standardizedFileURL.path else { throw BalancedAudioError.identityConflict }
            path = segment.recordingID.uuidString + "/" + segment.streamID + "/" + segment.filename
        } else { path = file.path }
        let entry = Entry(segment: segment, path: path, confirmed: false)
        try BalancedAudioIO.save(entry, to: metadataURL(segment)); entries[segment.key] = entry
        pendingKeys.append(segment.key)
    }
    func acknowledge(_ receipt: BalancedSegmentReceipt) throws {
        lock.lock(); defer { lock.unlock() }; try load()
        guard var entry = entries[receipt.segment.key], entry.segment == receipt.segment else { throw BalancedAudioError.identityConflict }
        guard !entry.confirmed else { return }
        entry.confirmed = true
        try BalancedAudioIO.save(entry, to: metadataURL(entry.segment)); entries[entry.segment.key] = entry
    }
    private static func finalReceipt(_ manifest: BalancedRecordingManifest) throws -> BalancedRecordingReceipt {
        BalancedRecordingReceipt(recordingID: manifest.recordingID, manifestSHA256: try manifest.digest(),
            segmentCount: manifest.segmentCount, byteCount: manifest.byteCount, durationFrames: manifest.durationFrames)
    }
    func acknowledge(_ receipt: BalancedRecordingReceipt, manifest: BalancedRecordingManifest) throws {
        lock.lock(); defer { lock.unlock() }; try load()
        guard receipt == (try Self.finalReceipt(manifest)) else { throw BalancedAudioError.identityConflict }
        let segments = manifest.streams.flatMap(\.segments)
        guard segments.allSatisfy({ entries[$0.key]?.segment == $0 }),
              entries.values.filter({ $0.segment.recordingID == manifest.recordingID }).count == segments.count
        else { throw BalancedAudioError.identityConflict }
        // One durable proof covers lost individual ACKs. A crash before updating
        // the in-memory flags recovers the same completed inventory on restart.
        try BalancedAudioIO.save(FinalProof(manifest: manifest, receipt: receipt),
                                 to: root.appendingPathComponent(manifest.recordingID.uuidString + ".receipt"))
        for segment in segments { entries[segment.key]?.confirmed = true }
    }
    func pending(excluding excluded: Set<String> = [], limit: Int = 12) throws -> [(BalancedAudioSegment, URL)] {
        lock.lock(); defer { lock.unlock() }; try load()
        guard limit > 0, limit <= 128 else { return [] }
        // Scan the inventory once on restart, then advance a cursor. A 12-hour
        // recording must not repeatedly sort/scan all previous segments per ACK.
        while pendingHead < pendingKeys.count, entries[pendingKeys[pendingHead]]?.confirmed != false { pendingHead += 1 }
        var result: [(BalancedAudioSegment, URL)] = []
        for key in pendingKeys.dropFirst(pendingHead) {
            guard !excluded.contains(key), let entry = entries[key], !entry.confirmed else { continue }
            result.append((entry.segment, sourceURL(entry.segment, storedPath: entry.path)))
            if result.count == limit { break }
        }
        return result
    }
    func completedReceipt(recordingID: UUID) throws -> BalancedRecordingReceipt? {
        lock.lock(); defer { lock.unlock() }; try load()
        let file = root.appendingPathComponent(recordingID.uuidString + ".receipt")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let proof = try JSONDecoder().decode(FinalProof.self, from: Data(contentsOf: file))
        guard proof.receipt.recordingID == recordingID, proof.receipt == (try Self.finalReceipt(proof.manifest))
        else { throw BalancedAudioError.identityConflict }
        return proof.receipt
    }
    func reopen(_ ranges: [BalancedMissingRange], recordingID: UUID) throws {
        lock.lock(); defer { lock.unlock() }; try load()
        guard ranges.count <= 64, ranges.allSatisfy({ BalancedAudioSegment.validStream($0.streamID) &&
            $0.firstIndex >= 0 && $0.lastIndex >= $0.firstIndex && $0.lastIndex < 100_000 }) else { throw BalancedAudioError.invalidDescriptor }
        for key in Array(entries.keys) {
            guard var entry = entries[key], entry.segment.recordingID == recordingID, entry.confirmed,
                  ranges.contains(where: { $0.streamID == entry.segment.streamID && ($0.firstIndex...$0.lastIndex).contains(entry.segment.index) }) else { continue }
            entry.confirmed = false
            try BalancedAudioIO.save(entry, to: metadataURL(entry.segment)); entries[key] = entry
        }
        let proof = root.appendingPathComponent(recordingID.uuidString + ".receipt")
        if FileManager.default.fileExists(atPath: proof.path) {
            try FileManager.default.moveItem(at: proof, to: proof.appendingPathExtension("invalidated-" + UUID().uuidString))
        }
        pendingKeys = entries.values.filter { !$0.confirmed }.sorted { $0.segment.index < $1.segment.index }.map { $0.segment.key }
        pendingHead = 0
    }
}

/// Pure timing policy; OS queue events perform the actual handoff. No repeating
/// reachability probes or timer is needed while disconnected.
struct BalancedSyncPolicy: Sendable {
    var livePreviewRequested = false
    var lowPower = false
    var recording = true
    var sessionActivated = true
    var liveReachable = false
    var queuedSegments = 0
    var firstSegment = false
    var oldestQueuedAt: Date?
    var nextRetryAt = Date.distantPast
    func canFlush(at now: Date, connectivityEvent: Bool = false) -> Bool {
        // Background file handoff is valid even while the counterpart is
        // unreachable. The OS queue, not a radio-polling loop, waits for it.
        guard sessionActivated, queuedSegments > 0, now >= nextRetryAt else { return false }
        if connectivityEvent || !recording || firstSegment { return true }
        if livePreviewRequested && liveReachable && !lowPower { return true }
        return queuedSegments >= 6 || oldestQueuedAt.map { now.timeIntervalSince($0) >= 60 } == true
    }
}

/// A bounded transport container copies canonical AAC bytes, never decodes or
/// re-encodes them. One background file can carry a minute of ten-second assets.
enum BalancedAudioBatch {
    private static let magic = Data("TalkTuckAudioBatch1\n".utf8)
    static let maximumSegments = 12
    static let maximumHeaderBytes = 32 * 1024

    static func write(_ items: [(BalancedAudioSegment, URL)], to destination: URL) throws {
        guard !items.isEmpty, items.count <= maximumSegments,
              Set(items.map { $0.0.key }).count == items.count,
              items.allSatisfy({ $0.0.isValid }),
              Set(items.map { $0.0.recordingID }).count == 1 else { throw BalancedAudioError.invalidDescriptor }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = try encoder.encode(items.map { $0.0 })
        guard header.count <= maximumHeaderBytes else { throw BalancedAudioError.invalidDescriptor }
        let manager = FileManager.default, parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".batch-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
        try output.write(contentsOf: magic)
        var length = UInt32(header.count).bigEndian
        try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: header)
        for (segment, file) in items {
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            var bytes: Int64 = 0, digest = SHA256()
            while let data = try input.read(upToCount: 65_536), !data.isEmpty {
                bytes += Int64(data.count)
                guard bytes <= segment.byteCount else { throw BalancedAudioError.integrityFailure }
                digest.update(data: data); try output.write(contentsOf: data)
            }
            guard bytes == segment.byteCount,
                  digest.finalize().map({ String(format: "%02x", $0) }).joined() == segment.sha256 else {
                throw BalancedAudioError.integrityFailure
            }
        }
        try output.synchronize(); try output.close()
        guard !manager.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try manager.moveItem(at: temporary, to: destination); try BalancedAudioIO.syncDirectory(parent)
    }

    static func receive(_ source: URL, inbox: BalancedAudioInbox, expectedRecordingID: UUID? = nil) throws -> [BalancedSegmentReceipt] {
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        func read(_ count: Int) throws -> Data {
            var value = Data()
            while value.count < count {
                guard let bytes = try input.read(upToCount: count - value.count), !bytes.isEmpty else { throw BalancedAudioError.integrityFailure }
                value.append(bytes)
            }
            return value
        }
        guard try read(magic.count) == magic else { throw BalancedAudioError.invalidDescriptor }
        let size = try read(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= maximumHeaderBytes else { throw BalancedAudioError.invalidDescriptor }
        let segments = try JSONDecoder().decode([BalancedAudioSegment].self, from: read(Int(size)))
        guard !segments.isEmpty, segments.count <= maximumSegments, segments.allSatisfy(\.isValid),
              Set(segments.map(\.key)).count == segments.count,
              Set(segments.map(\.recordingID)).count == 1,
              expectedRecordingID == nil || segments.allSatisfy({ $0.recordingID == expectedRecordingID }) else { throw BalancedAudioError.invalidDescriptor }
        try FileManager.default.createDirectory(at: inbox.root, withIntermediateDirectories: true)
        var receipts: [BalancedSegmentReceipt] = []
        for segment in segments {
            let temporary = inbox.root.appendingPathComponent(".incoming-" + UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
            var remaining = segment.byteCount
            while remaining > 0 {
                let data = try read(Int(min(65_536, remaining)))
                try output.write(contentsOf: data); remaining -= Int64(data.count)
            }
            try output.close()
            receipts.append(try inbox.receive(temporary, segment: segment))
        }
        guard (try input.read(upToCount: 1))?.isEmpty != false else { throw BalancedAudioError.integrityFailure }
        return receipts
    }
}
