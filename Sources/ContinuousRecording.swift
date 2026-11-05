import AVFoundation
import Foundation

/// 录音会话类型。会议模式保留一条完整音频；持续录音按边界生成可独立处理的片段。
enum RecordingSessionMode: String, CaseIterable, Identifiable, Codable {
    case conference, continuous
    var id: String { rawValue }
    var title: String { L10n.text(self == .conference ? "整段录音" : "持续录音") }
    var detail: String {
        self == .conference
            ? "保留完整录音上下文，停止后统一识别、分人和对齐。"
            : "按最长时长和连续静音自动切片；录音继续时，已关闭片段依次定稿、分人和对齐。"
    }
}

struct ContinuousSegmentPolicy: Equatable, Sendable {
    var maximumSeconds: TimeInterval = 300
    var minimumSeconds: TimeInterval = 20
    var trailingSilenceSeconds: TimeInterval = 2
    var silenceThreshold: Float = 0.008
    var sampleRate: Double = 16_000

    var maximumFrames: Int { Int(maximumSeconds * sampleRate) }
    var minimumFrames: Int { Int(minimumSeconds * sampleRate) }
    var trailingSilenceFrames: Int { Int(trailingSilenceSeconds * sampleRate) }
}

struct ContinuousSegmentInfo: Codable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let start: TimeInterval
    let duration: TimeInterval
    var status: String = "queued"
}

/// 在实时混音回调上工作。只负责边界和稳定落盘，不在音频队列中启动模型。
final class ContinuousRecordingSegmenter: @unchecked Sendable {
    private let policy: ContinuousSegmentPolicy
    private let directory: URL
    private let queue = DispatchQueue(label: "com.xsg.talktuck.continuous-segments", qos: .userInitiated)
    private let onClosed: (ContinuousSegmentInfo) -> Void
    private let onError: ((Error) -> Void)?
    private var file: AVAudioFile?
    private var segmentID: UUID?
    private var segmentStart: TimeInterval = 0
    private var frames = 0
    private var silentFrames = 0
    private var failed: Error?
    private var finished = false
    private var segments: [ContinuousSegmentInfo] = []
    private var preRoll: [Float] = []
    private var canonicalArchive: URL?
    private let timelineOffset: TimeInterval
    private var loadedQueue = false

    func bindCanonicalArchive(_ root: URL) {
        queue.sync { canonicalArchive = root }
    }

    init(directory: URL, policy: ContinuousSegmentPolicy = .init(), timelineOffset: TimeInterval = 0,
         onError: ((Error) -> Void)? = nil, onClosed: @escaping (ContinuousSegmentInfo) -> Void) {
        self.directory = directory; self.policy = policy; self.timelineOffset = timelineOffset; self.onError = onError; self.onClosed = onClosed
    }

    func append(_ samples: [Float], at offset: TimeInterval) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard !finished, failed == nil else { return }
            do {
                let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
                let voiced = rms >= policy.silenceThreshold
                if segmentID == nil {
                    guard voiced else {
                        preRoll.append(contentsOf: samples)
                        if preRoll.count > Int(policy.sampleRate * 0.2) { preRoll.removeFirst(preRoll.count - Int(policy.sampleRate * 0.2)) }
                        return
                    }
                    let start = max(0, offset - Double(preRoll.count) / policy.sampleRate)
                    try open(start: start)
                    if !preRoll.isEmpty { try write(preRoll); preRoll = [] }
                }
                try write(samples)
                silentFrames = voiced ? 0 : silentFrames + samples.count
                if frames >= policy.maximumFrames || (frames >= policy.minimumFrames && silentFrames >= policy.trailingSilenceFrames) { try close() }
            } catch { failed = error; onError?(error) }
        }
    }

    private func write(_ samples: [Float]) throws {
        if canonicalArchive != nil { frames += samples.count; return }
        guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw MeetingRecorderError.message("无法写入持续录音片段。")
        }
        guard let target = buffer.floatChannelData?.pointee else { throw MeetingRecorderError.message("持续录音缓冲区格式无效。") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let source = source.baseAddress { target.update(from: source, count: samples.count) }
        }
        try file.write(from: buffer)
        frames += samples.count
    }

    func finish() -> [ContinuousSegmentInfo] {
        queue.sync {
            guard !finished else { return segments }
            if segmentID != nil { do { try close() } catch { failed = error; onError?(error) } }
            finished = true
            return segments
        }
    }

    func setStatus(_ status: String, for id: UUID) {
        queue.sync {
            guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
            segments[index].status = status
            if let data = try? JSONEncoder().encode(segments) {
                try? data.write(to: directory.appendingPathComponent("segments.json"), options: .atomic)
            }
        }
    }

    var error: Error? { queue.sync { failed } }

    private func open(start: TimeInterval) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !loadedQueue { segments = try ContinuousRecordingQueue.load(directory); loadedQueue = true }
        let id = UUID(); segmentID = id; segmentStart = max(0, start); frames = 0; silentFrames = 0
        if canonicalArchive != nil { return }
        let url = directory.appendingPathComponent("segment-\(id.uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: policy.sampleRate, channels: 1)!
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func close() throws {
        guard let id = segmentID else { return }
        let url: URL
        if let canonicalArchive {
            guard let source = UUID(uuidString: canonicalArchive.lastPathComponent) else { throw BalancedAudioError.invalidManifest }
            url = directory.appendingPathComponent("segment-\(id.uuidString).json")
            let start = Int64((segmentStart * 16_000).rounded())
            try BalancedAudioIO.save(CanonicalAudioRange(sourceRecordingID: source, startFrame: start, endFrame: start + Int64(frames)), to: url)
        } else {
            guard let file else { return }; url = file.url; self.file = nil
        }
        let info = ContinuousSegmentInfo(id: id, url: url, start: timelineOffset + segmentStart, duration: Double(frames) / policy.sampleRate)
        segments.append(info)
        try JSONEncoder().encode(segments).write(to: directory.appendingPathComponent("segments.json"), options: .atomic)
        onClosed(info)
        segmentID = nil; frames = 0; silentFrames = 0
    }
}


/// Capture-local frames remain unchanged; transcript positions use the meeting timeline.
struct CanonicalCaptureContext: Codable, Sendable {
    let mode: RecordingSessionMode
    let meetingOffset: TimeInterval
    static func read(_ directory: URL) throws -> Self? {
        let url = directory.appendingPathComponent("capture-context.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL,
              let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= 4096 else { throw BalancedAudioError.invalidManifest }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.meetingOffset.isFinite, value.meetingOffset >= 0 else { throw BalancedAudioError.invalidManifest }
        return value
    }
}

enum ContinuousRecordingQueue {
    static func load(_ directory: URL) throws -> [ContinuousSegmentInfo] {
        let url = directory.appendingPathComponent("segments.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL,
              let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.int64Value <= 8 * 1024 * 1024 else { throw BalancedAudioError.invalidManifest }
        let rows = try JSONDecoder().decode([ContinuousSegmentInfo].self, from: Data(contentsOf: url))
        guard rows.count <= 20_000, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration > 0 &&
                  $0.url.isFileURL && $0.url.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path &&
                  $0.url.resolvingSymlinksInPath() == $0.url.standardizedFileURL }) else { throw BalancedAudioError.invalidManifest }
        return rows
    }

    /// Recover only uncovered source ranges. Persist the plan before library registration,
    /// so a crash between the two steps reuses the same chapter IDs on the next attempt.
    static func recover(recordingID: UUID, frames: Int64, meetingOffset: Double,
                        directory: URL) throws -> [ContinuousSegmentInfo] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rows = try load(directory)
        var covered: [(Int64, Int64)] = []
        for item in rows where item.url.pathExtension == "json" {
            let range = try JSONDecoder().decode(CanonicalAudioRange.self, from: Data(contentsOf: item.url))
            guard range.sourceRecordingID == recordingID else { continue }
            guard range.startFrame >= 0, range.endFrame > range.startFrame, range.endFrame <= frames else { throw BalancedAudioError.invalidManifest }
            covered.append((range.startFrame, range.endFrame))
        }
        covered.sort { $0.0 < $1.0 }
        var cursor: Int64 = 0
        func add(_ end: Int64) throws {
            while cursor < end {
                let next = min(end, cursor + 300 * 16_000), id = UUID()
                let url = directory.appendingPathComponent("segment-" + id.uuidString + ".json")
                try BalancedAudioIO.save(CanonicalAudioRange(sourceRecordingID: recordingID, startFrame: cursor, endFrame: next), to: url)
                rows.append(ContinuousSegmentInfo(id: id, url: url, start: meetingOffset + Double(cursor) / 16_000,
                    duration: Double(next - cursor) / 16_000))
                cursor = next
            }
        }
        for interval in covered {
            guard interval.0 >= cursor else { throw BalancedAudioError.invalidManifest }
            try add(interval.0); cursor = interval.1
        }
        try add(frames)
        rows.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        try BalancedAudioIO.save(rows, to: directory.appendingPathComponent("segments.json"))
        return try rows.filter {
            guard $0.url.pathExtension == "json" else { return false }
            return try JSONDecoder().decode(CanonicalAudioRange.self, from: Data(contentsOf: $0.url)).sourceRecordingID == recordingID
        }
    }

    static func pending(_ rows: [ContinuousSegmentInfo], record: MeetingRecord) -> [ContinuousSegmentInfo] {
        rows.map { row in
            var item = row
            if let file = record.importedCaptureSessions[row.id.uuidString] {
                item.status = record.pendingAudioFiles.contains(file) ? "queued" : (row.status == "partial" ? "partial" : "completed")
            }
            return item
        }
    }
}
