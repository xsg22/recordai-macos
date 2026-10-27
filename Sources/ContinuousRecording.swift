import AVFoundation
import Foundation

/// 录音会话类型。会议模式保留一条完整音频；持续录音按边界生成可独立处理的片段。
enum RecordingSessionMode: String, CaseIterable, Identifiable, Codable {
    case conference, continuous
    var id: String { rawValue }
    var title: String { self == .conference ? "会议录音" : "持续录音" }
    var detail: String {
        self == .conference
            ? "保留完整会议上下文，停止后统一识别、分人和对齐。"
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
    private let queue = DispatchQueue(label: "com.byering.recordai.continuous-segments", qos: .userInitiated)
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

    init(directory: URL, policy: ContinuousSegmentPolicy = .init(),
         onError: ((Error) -> Void)? = nil, onClosed: @escaping (ContinuousSegmentInfo) -> Void) {
        self.directory = directory; self.policy = policy; self.onError = onError; self.onClosed = onClosed
    }

    func append(_ samples: [Float], at offset: TimeInterval) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard !finished, failed == nil else { return }
            do {
                let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
                let voiced = rms >= policy.silenceThreshold
                if file == nil {
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
            if file != nil { do { try close() } catch { failed = error; onError?(error) } }
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
        let id = UUID(); segmentID = id; segmentStart = max(0, start); frames = 0; silentFrames = 0
        let url = directory.appendingPathComponent("segment-\(id.uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: policy.sampleRate, channels: 1)!
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func close() throws {
        guard let file, let id = segmentID else { return }
        let url = file.url; self.file = nil
        let info = ContinuousSegmentInfo(id: id, url: url, start: segmentStart, duration: Double(frames) / policy.sampleRate)
        segments.append(info)
        try JSONEncoder().encode(segments).write(to: directory.appendingPathComponent("segments.json"), options: .atomic)
        onClosed(info)
        segmentID = nil; frames = 0; silentFrames = 0
    }
}
