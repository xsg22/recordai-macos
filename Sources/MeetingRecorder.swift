import AVFoundation
import CoreMedia
import Darwin
import ScreenCaptureKit

/// 系统声音和麦克风始终独立落盘，混音失败也不会丢失原始录音。
enum MeetingRecordingMode: String, CaseIterable, Identifiable {
    case microphone, systemAudio, meeting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .systemAudio: return "系统声音"
        case .meeting: return "会议 · 麦克风和系统声音"
        }
    }
    var needsMicrophone: Bool { self != .systemAudio }
    var needsSystemAudio: Bool { self != .microphone }
}

struct MeetingRecording {
    let audioURL: URL
    let microphoneURL: URL?
    let systemAudioURL: URL?
    let seconds: TimeInterval
    var warning: String? = nil
}

enum MeetingRecorderError: LocalizedError {
    case message(String)
    case microphoneStalled
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .microphoneStalled:
            return "麦克风已停止提供音频，可能已断开。请重新连接输入设备后重试继续；已有录音会保留。"
        }
    }
}

@MainActor
final class MeetingRecorder {
    enum State { case idle, preparing, recording, paused, finishing }
    private(set) var state: State = .idle
    var onUpdate: ((TimeInterval, Float) -> Void)?
    var onError: ((Error) -> Void)?
    /// 在 start 前设置。串行录音队列回调 16 kHz 单声道 Float32，每批最多 1600 个样本。
    /// 回调必须立即投递给异步消费者，不得同步执行模型或阻塞管道写入。
    var onAudio: (([Float]) -> Void)?
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var sink: MeetingAudioSink?
    private var timer: Timer?
    private var recordingActivity: NSObjectProtocol?
    private var directory: URL?
    private var started: TimeInterval = 0
    private var pausedAt: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    private var failure: Error?
    private(set) var canRetryMicrophone = false
    private var configurationObserver: NSObjectProtocol?
    private var seconds: TimeInterval {
        max(0, (pausedAt ?? MeetingCaptureTimeline.now) - started - pausedDuration)
    }

    /// directory 应传入 App 自有 Recordings 目录；每次录音创建唯一子目录。
    func start(mode: MeetingRecordingMode, directory root: URL,
               sessionMode: RecordingSessionMode = .conference,
               segmenter: ContinuousRecordingSegmenter? = nil) async throws {
        guard state == .idle else { throw MeetingRecorderError.message("已有录音正在进行。") }
        state = .preparing
        do {
            if mode.needsMicrophone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw MeetingRecorderError.message("请在系统设置 → 隐私与安全性 → 麦克风中允许录音。")
                }
            }
            // 先获取系统录音权限和目标，避免系统权限失败后留下正在录制的麦克风。
            var filter: SCContentFilter?
            if mode.needsSystemAudio {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    throw MeetingRecorderError.message("没有可用显示器，无法采集系统声音。")
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
            failure = nil
            canRetryMicrophone = false
            pausedAt = nil
            pausedDuration = 0
            started = MeetingCaptureTimeline.now
            recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "正在本地录制会议音频")
            let sink = MeetingAudioSink(directory: directory, started: started, mode: mode, sessionMode: sessionMode, segmenter: segmenter, onAudio: onAudio) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.state == .preparing || self.state == .recording || self.state == .paused else { return }
                    self.reportFailure(error)
                }
            }
            self.sink = sink
            if let filter {
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                self.stream = stream
                try await stream.startCapture()
            }
            if mode.needsMicrophone {
                try startMicrophoneCapture(sink: sink)
            }
            if let failure { throw failure }
            state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.state == .recording, mode.needsMicrophone,
                       CaptureHealth.microphoneStalled(started: self.started, lastFrame: self.sink?.lastFrame(for: .microphone), now: MeetingCaptureTimeline.now) {
                        self.canRetryMicrophone = true
                        self.reportFailure(MeetingRecorderError.microphoneStalled)
                    }
                    self.onUpdate?(self.seconds, self.state == .paused ? 0 : self.sink?.level ?? 0)
                }
            }
        } catch {
            removeConfigurationObserver()
            if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
            engine = nil
            if let stream { try? await stream.stopCapture() }
            stream = nil
            sink?.finish()
            sink = nil
            if let recordingActivity { ProcessInfo.processInfo.endActivity(recordingActivity) }
            recordingActivity = nil
            state = .idle
            throw error
        }
    }

    private func reportFailure(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        pause()
        onError?(error)
    }
    private func removeConfigurationObserver() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    func pause() {
        guard state == .recording else { return }
        pausedAt = MeetingCaptureTimeline.now
        sink?.setPaused(true)
        state = .paused
    }

    @discardableResult
    func resume() -> Bool {
        guard state == .paused else { return false }
        if canRetryMicrophone {
            do {
                removeConfigurationObserver()
                if let engine {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
                engine = nil
                guard let sink else {
                    throw MeetingRecorderError.message("录音音轨不可用，已有录音仍会保留；请停止并保存。")
                }
                try startMicrophoneCapture(sink: sink)
            } catch {
                failure = error
                onError?(error)
                return false
            }
        } else if failure != nil {
            return false
        }
        if let pausedAt { pausedDuration += MeetingCaptureTimeline.now - pausedAt }
        pausedAt = nil
        sink?.setPaused(false)
        state = .recording
        failure = nil
        canRetryMicrophone = false
        return true
    }

    private func startMicrophoneCapture(sink: MeetingAudioSink) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingRecorderError.message("麦克风不可用，请检查输入设备。")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            sink.appendMicrophone(buffer, at: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : MeetingCaptureTimeline.now - Double(buffer.frameLength) / buffer.format.sampleRate)
        }
        self.engine = engine
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            throw error
        }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.reportFailure(MeetingRecorderError.message("输入设备或采样率已变化，已有录音已保留。请保存后重新开始。"))
            }
        }
    }

    /// 返回可直接送入转录引擎的音频；错误发生时原始 CAF 文件仍留在唯一录音目录。
    func stop() async throws -> MeetingRecording {
        guard state == .recording || state == .paused, let sink, let directory else {
            throw MeetingRecorderError.message("没有正在进行的录音。")
        }
        let duration = seconds
        removeConfigurationObserver()
        state = .finishing
        sink.setPaused(true) // 停止边界之后抵达的音频不能再延长最终文件。
        timer?.invalidate()
        timer = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        var stopFailure: Error?
        if let stream {
            do { try await stream.stopCapture() } catch { stopFailure = error }
        }
        stream = nil
        let tracks = sink.finish()
        self.sink = nil
        defer {
            if let recordingActivity { ProcessInfo.processInfo.endActivity(recordingActivity) }
            recordingActivity = nil
            state = .idle
        }
        let captureWarning = (failure ?? stopFailure ?? sink.recordingError)?.localizedDescription
        guard !tracks.isEmpty else {
            throw MeetingRecorderError.message("未采集到音频，请检查系统权限和输入设备。")
        }
        let destination = directory.appendingPathComponent("meeting.m4a")
        do { try await MeetingAudioMixer.mix(tracks: tracks, destination: destination, duration: duration) }
        catch {
            throw MeetingRecorderError.message("录音原轨已保存至 \(directory.path)，合成失败：\(error.localizedDescription)")
        }
        return MeetingRecording(audioURL: destination,
                                microphoneURL: tracks.first { $0.kind == .microphone }?.url,
                                systemAudioURL: tracks.first { $0.kind == .system }?.url,
                                seconds: duration, warning: captureWarning)
    }
}

struct MeetingAudioTrack: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case microphone, system }
    let kind: Kind
    let url: URL
    let offset: TimeInterval
}

/// 麦克风 hostTime 与 ScreenCaptureKit PTS 都使用 CoreMedia host clock；禁止用回调抵达时间对齐。
struct MeetingCaptureTimeline {
    static var now: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
    let started: TimeInterval
    private var pauses: [Range<TimeInterval>] = []
    private var pauseStart: TimeInterval?

    mutating func setPaused(_ value: Bool, at timestamp: TimeInterval) {
        if value, pauseStart == nil { pauseStart = timestamp }
        if !value, let start = pauseStart {
            pauses.append(start..<max(start, timestamp))
            pauseStart = nil
        }
    }

    func slices(at timestamp: TimeInterval, frames: Int, sampleRate: Double) -> [(frames: Range<Int>, offset: TimeInterval)] {
        guard timestamp.isFinite, sampleRate > 0, frames > 0 else { return [] }
        let end = timestamp + Double(frames) / sampleRate
        var active = [max(started, timestamp)..<max(max(started, timestamp), end)]
        let excluded = pauses + (pauseStart.map { [$0..<max($0, end)] } ?? [])
        for pause in excluded {
            active = active.flatMap { range -> [Range<TimeInterval>] in
                guard pause.lowerBound < range.upperBound, pause.upperBound > range.lowerBound else { return [range] }
                var parts: [Range<TimeInterval>] = []
                if range.lowerBound < pause.lowerBound { parts.append(range.lowerBound..<pause.lowerBound) }
                if pause.upperBound < range.upperBound { parts.append(pause.upperBound..<range.upperBound) }
                return parts
            }
        }
        return active.compactMap { range in
            let lower = min(frames, max(0, Int(((range.lowerBound - timestamp) * sampleRate).rounded())))
            let upper = min(frames, max(lower, Int(((range.upperBound - timestamp) * sampleRate).rounded())))
            guard lower < upper else { return nil }
            let removed = pauses.reduce(0) { $0 + max(0, min(range.lowerBound, $1.upperBound) - $1.lowerBound) }
            return (lower..<upper, max(0, range.lowerBound - started - removed))
        }
    }
}

/// 所有写盘操作串行执行；tap 回调先复制 buffer，避免 AVAudioEngine 复用内存。
final class MeetingAudioSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.byering.cohear.meeting-audio", qos: .userInitiated)
    private let directory: URL
    private let onError: (Error) -> Void
    private let segmenter: ContinuousRecordingSegmenter?
    private var files: [MeetingAudioTrack.Kind: AVAudioFile] = [:]
    private var tracks: [MeetingAudioTrack] = []
    private var finished = false
    private var failed = false
    private var storedError: Error?
    var recordingError: Error? { queue.sync { storedError } }
    private var meter: Float = 0
    private var timeline: MeetingCaptureTimeline
    private var live: MeetingLiveAudioMixer?
    private var livePaused = false
    private var resamplers: [MeetingAudioTrack.Kind: MeetingLiveResampler] = [:]
    /// 快速锁只保护采样快照，主线程不等待磁盘写入队列。
    private let healthLock = NSLock()
    private var lastFrames: [MeetingAudioTrack.Kind: TimeInterval] = [:]
    var level: Float {
        healthLock.lock(); defer { healthLock.unlock() }
        let result = meter; meter = 0
        return result
    }
    func lastFrame(for kind: MeetingAudioTrack.Kind) -> TimeInterval? {
        healthLock.lock(); defer { healthLock.unlock() }
        return lastFrames[kind]
    }

    init(directory: URL, started: TimeInterval, mode: MeetingRecordingMode = .microphone,
         sessionMode: RecordingSessionMode = .conference,
         segmenter: ContinuousRecordingSegmenter? = nil,
         onAudio: (([Float]) -> Void)? = nil, onError: @escaping (Error) -> Void) {
        self.directory = directory
        self.timeline = MeetingCaptureTimeline(started: started)
        self.onError = onError
        let activeSegmenter = sessionMode == .continuous ? segmenter : nil
        self.segmenter = activeSegmenter
        if onAudio != nil || activeSegmenter != nil {
            live = MeetingLiveAudioMixer(trackCount: mode == .meeting ? 2 : 1) { samples, offset in
                onAudio?(samples)
                activeSegmenter?.append(samples, at: offset)
            }
        }
    }

    func setPaused(_ value: Bool) {
        let timestamp = MeetingCaptureTimeline.now
        queue.sync {
            timeline.setPaused(value, at: timestamp)
            livePaused = value
            healthLock.lock(); meter = 0; healthLock.unlock()
        }
        if value {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.livePaused, !self.finished else { return }
                self.live?.flush()
            }
        }
    }

    func appendMicrophone(_ buffer: AVAudioPCMBuffer, at timestamp: TimeInterval) {
        guard buffer.frameLength > 0 else { return }
        // 到达时间在采集回调记录，不把磁盘队列拥堵误判为设备断开。
        healthLock.lock(); lastFrames[.microphone] = MeetingCaptureTimeline.now; healthLock.unlock()
        guard let copy = Self.copy(buffer, frames: 0..<Int(buffer.frameLength)) else { return }
        queue.async { self.write(copy, kind: .microphone, at: timestamp) }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer, frames: Range<Int>) -> AVAudioPCMBuffer? {
        guard !frames.isEmpty, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames.count)) else { return nil }
        copy.frameLength = copy.frameCapacity
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, target) in zip(source, target) {
            let bytesPerFrame = Int(source.mDataByteSize) / Int(buffer.frameLength)
            if let src = source.mData, let dst = target.mData {
                memcpy(dst, src.advanced(by: frames.lowerBound * bytesPerFrame), frames.count * bytesPerFrame)
            }
        }
        return copy
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), !finished else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))) else { return }
        pcm.frameLength = pcm.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                                                                frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList)
        guard status == noErr else {
            report(MeetingRecorderError.message("系统音频解码失败（\(status)）。")); return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite else { report(MeetingRecorderError.message("系统音频缺少有效时间戳。")); return }
        write(pcm, kind: .system, at: timestamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.report(error) }
    }

    private func write(_ buffer: AVAudioPCMBuffer, kind: MeetingAudioTrack.Kind, at timestamp: TimeInterval) {
        guard !finished, !failed, buffer.frameLength > 0 else { return }
        for slice in timeline.slices(at: timestamp, frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate) {
            guard let active = Self.copy(buffer, frames: slice.frames) else { continue }
            writeActive(active, kind: kind, offset: slice.offset)
            if live != nil, !failed {
                do {
                    let resampler: MeetingLiveResampler
                    if let existing = resamplers[kind], existing.matches(active.format) { resampler = existing }
                    else {
                        resampler = try MeetingLiveResampler(format: active.format)
                        resamplers[kind] = resampler
                    }
                    let converted = try resampler.convert(active, offset: slice.offset)
                live?.append(converted.samples, kind: kind, offset: converted.offset)
                } catch { report(error) }
            }
        }
    }

    private func writeActive(_ buffer: AVAudioPCMBuffer, kind: MeetingAudioTrack.Kind, offset: TimeInterval) {
        guard !failed else { return }
        do {
            let file: AVAudioFile
            if let existing = files[kind] { file = existing }
            else {
                let url = directory.appendingPathComponent(kind == .microphone ? "microphone.caf" : "system.caf")
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                       commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                files[kind] = file
                tracks.append(MeetingAudioTrack(kind: kind, url: url, offset: offset))
                // 恢复清单先落盘，崩溃或后续磁盘满时也能找回轨道和相对起点。
                try JSONEncoder().encode(tracks).write(to: directory.appendingPathComponent("recording.json"), options: .atomic)
            }
            guard file.processingFormat.sampleRate == buffer.format.sampleRate,
                  file.processingFormat.channelCount == buffer.format.channelCount else {
                throw MeetingRecorderError.message("录音设备格式发生变化，已暂停并保留原轨。")
            }
            let origin = tracks.first { $0.kind == kind }!.offset
            let desiredFrame = AVAudioFramePosition(((offset - origin) * buffer.format.sampleRate).rounded())
            // 设备丢帧或回调间断时补静音，不能简单拼接使后续文字时间逐渐提前。
            var gap = desiredFrame - file.length
            while gap > 0 {
                let count = AVAudioFrameCount(min(gap, 8192))
                guard let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else {
                    throw MeetingRecorderError.message("无法创建静音缓冲区。")
                }
                silence.frameLength = count
                for block in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = block.mData { memset(data, 0, Int(block.mDataByteSize)) }
                }
                try file.write(from: silence)
                gap -= AVAudioFramePosition(count)
            }
            let overlap = Int(max(0, file.length - desiredFrame))
            if overlap < Int(buffer.frameLength), let remaining = Self.copy(buffer, frames: overlap..<Int(buffer.frameLength)) {
                try file.write(from: remaining)
            }
            if let channels = buffer.floatChannelData {
                var peak: Float = 0
                if buffer.format.isInterleaved {
                    for index in 0..<(Int(buffer.frameLength) * Int(buffer.format.channelCount)) {
                        let sample = abs(channels[0][index]); if sample.isFinite { peak = max(peak, sample) }
                    }
                } else {
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for frame in 0..<Int(buffer.frameLength) { let sample = abs(channels[channel][frame]); if sample.isFinite { peak = max(peak, sample) } }
                    }
                }
                healthLock.lock(); meter = min(1, max(peak, meter)); healthLock.unlock()
            }
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        guard !failed, !finished else { return }
        failed = true
        storedError = error
        onError(error)
    }

    @discardableResult func finish() -> [MeetingAudioTrack] {
        queue.sync {
            for (kind, resampler) in resamplers {
                do {
                    let tail = try resampler.finish()
                    live?.append(tail.samples, kind: kind, offset: tail.offset)
                } catch { report(error) }
            }
            live?.flush()
            live = nil
            resamplers.removeAll()
            finished = true
            files.removeAll() // 关闭 AVAudioFile，刷新 CAF 头部后再交给导出器。
            return tracks
        }
    }
}

/// AVAudioConverter 保持每轨滤波状态；使用 CoreAudio 重采样，避免直接抽样造成高频混叠。
final class MeetingLiveResampler {
    private let source: AVAudioFormat
    private let converter: AVAudioConverter
    private let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var anchor: TimeInterval?
    private var emitted = 0
    private var expectedInput: TimeInterval?

    init(format: AVAudioFormat) throws {
        source = format
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw MeetingRecorderError.message("无法创建实时音频重采样器。")
        }
        self.converter = converter
        converter.primeMethod = .none
        converter.downmix = true
    }

    func matches(_ format: AVAudioFormat) -> Bool { source == format }

    func convert(_ buffer: AVAudioPCMBuffer, offset: TimeInterval) throws -> (samples: [Float], offset: TimeInterval) {
        if anchor == nil || expectedInput.map({ abs(offset - $0) > 0.01 }) == true {
            converter.reset()
            anchor = offset
            emitted = 0
        }
        expectedInput = offset + Double(buffer.frameLength) / source.sampleRate
        let outputOffset = (anchor ?? offset) + Double(emitted) / 16_000
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / source.sampleRate) + 256)
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw error ?? MeetingRecorderError.message("实时音频重采样失败。") }
        emitted += Int(output.frameLength)
        return (Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))), outputOffset)
    }

    func finish() throws -> (samples: [Float], offset: TimeInterval) {
        let offset = (anchor ?? 0) + Double(emitted) / 16_000
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 512)!
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error else { throw error ?? MeetingRecorderError.message("实时音频尾段转换失败。") }
        emitted += Int(output.frameLength)
        return (Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))), offset)
    }
}

/// 16 kHz 共同时间轴环形混音器；只保留 0.5 秒 PCM，等待另一轨最多约 200ms。
/// 超过窗口才抵达的迟到样本不会修改已经交给 ASR 的内容，最终原轨不受此限制。
final class MeetingLiveAudioMixer {
    private let capacity = 8000
    private let holdback = 3200
    private var ring = [Float](repeating: 0, count: 8000)
    private var sources = [UInt8](repeating: 0, count: 8000)
    private var cursor = 0
    private var latest = 0
    private let gain: Float
    private let onAudio: ([Float], TimeInterval) -> Void
    var bufferedFrames: Int { min(capacity, max(0, latest - cursor)) }

    init(trackCount: Int, onAudio: @escaping ([Float], TimeInterval) -> Void) {
        gain = 0.9 / Float(max(1, trackCount))
        self.onAudio = onAudio
    }

    func append(_ samples: [Float], kind: MeetingAudioTrack.Kind, offset: TimeInterval) {
        guard offset.isFinite, offset >= 0, !samples.isEmpty else { return }
        let start = Int((offset * 16_000).rounded())
        let bit: UInt8 = kind == .microphone ? 1 : 2
        for (index, sample) in samples.enumerated() {
            let frame = start + index
            guard frame >= cursor else { continue }
            // shortcut: 系统声音独占且长时间无回调时仍逐帧补静音；完成24小时系统音频压测后再优化稀疏间隙。
            if frame >= cursor + capacity { emit(until: frame - capacity + 1) }
            let slot = frame % capacity
            if sources[slot] & bit == 0 {
                ring[slot] += (sample.isFinite ? sample : 0) * gain
                sources[slot] |= bit
            }
        }
        latest = max(latest, start + samples.count)
        emit(until: max(cursor, latest - holdback))
    }

    func flush() { emit(until: latest) }

    private func emit(until ending: Int) {
        while cursor < ending {
            let count = min(1600, ending - cursor)
            var output = [Float]()
            output.reserveCapacity(count)
            for _ in 0..<count {
                let slot = cursor % capacity
                output.append(min(1, max(-1, ring[slot])))
                ring[slot] = 0
                sources[slot] = 0
                cursor += 1
            }
            onAudio(output, Double(cursor - count) / 16_000)
        }
    }
}

/// 使用系统媒体框架合成，按轨数分配增益并预留 10% 编码余量，原轨保持完整音量。
enum MeetingAudioMixer {
    static func mix(tracks: [MeetingAudioTrack], destination: URL, duration: TimeInterval? = nil) async throws {
        guard !tracks.isEmpty, tracks.allSatisfy({ $0.offset.isFinite && $0.offset >= 0 }) else {
            throw MeetingRecorderError.message("没有有效录音轨道。")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MeetingRecorderError.message("合成目标已存在，未覆盖已有文件。")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("mix-\(UUID().uuidString).partial.m4a")
        let padding = temporary.deletingPathExtension().appendingPathExtension("caf")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: padding)
        }
        let composition = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        for track in tracks {
            let asset = AVURLAsset(url: track.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MeetingRecorderError.message("无法读取录音轨道：\(track.url.lastPathComponent)")
            }
            let range = try await source.load(.timeRange)
            try target.insertTimeRange(range, of: source,
                                       at: CMTime(seconds: track.offset, preferredTimescale: 48_000))
            let parameter = AVMutableAudioMixInputParameters(track: target)
            parameter.setVolume(0.9 / Float(tracks.count), at: .zero)
            parameters.append(parameter)
        }
        if let duration {
            guard duration.isFinite, duration > 0 else { throw MeetingRecorderError.message("录音时长无效。") }
            let ending = CMTime(seconds: duration, preferredTimescale: 48_000)
            if composition.duration < ending {
                // AVAssetExportSession 会丢弃纯 empty range 尾部，必须添加真实静音 PCM。
                let start = composition.duration
                try writeSilence(url: padding, seconds: (ending - start).seconds)
                let silenceAsset = AVURLAsset(url: padding)
                guard let source = try await silenceAsset.loadTracks(withMediaType: .audio).first,
                      let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MeetingRecorderError.message("无法补齐录音尾部静音。")
                }
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: ending - start), of: source, at: start)
            }
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingRecorderError.message("无法创建音频合成器。")
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        exporter.audioMix = mix
        if let duration { exporter.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 48_000)) }
        exporter.outputURL = temporary
        exporter.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else {
            throw exporter.error ?? MeetingRecorderError.message("音频合成未完成。")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func writeSilence(url: URL, seconds: TimeInterval) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var remaining = AVAudioFramePosition((seconds * 48_000).rounded(.up))
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, 8192))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            memset(buffer.floatChannelData![0], 0, Int(count) * MemoryLayout<Float>.size)
            try file.write(from: buffer)
            remaining -= AVAudioFramePosition(count)
        }
    }

}
