import AVFoundation
import CoreAudio
import CoreMedia
import Darwin
import ScreenCaptureKit

/// 系统声音和麦克风始终独立落盘，混音失败也不会丢失原始录音。
enum MeetingRecordingMode: String, CaseIterable, Identifiable {
    case microphone, systemAudio, meeting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: return L10n.text("麦克风")
        case .systemAudio: return L10n.text("系统声音")
        case .meeting: return L10n.text("麦克风 + 系统声音")
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

struct MeetingCaptureRequest {
    let mode: MeetingRecordingMode
    let directory: URL
    let sessionMode: RecordingSessionMode
    let meetingOffset: Double
    let segmenter: ContinuousRecordingSegmenter?
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
    static func requireMicrophone() throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else {
            throw MeetingRecorderError.message("没有可用的麦克风输入设备。请连接麦克风并在系统设置中选择输入设备，或选择系统声音录音。")
        }
    }
    enum State { case idle, preparing, recording, paused, finishing }
    private(set) var state: State = .idle
    var onUpdate: ((TimeInterval, Float) -> Void)?
    var onError: ((Error) -> Void)?
    /// 在 start 前设置。串行录音队列回调 16 kHz 单声道 Float32，每批最多 1600 个样本。
    /// 回调必须立即投递给异步消费者，不得同步执行模型或阻塞管道写入。
    var onAudio: (([Float]) -> Void)?
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var systemDelegate: MeetingSystemAudioDelegate?
    private var sessionID = UUID()
    private var sourceSwitchID: UUID?
    private(set) var activeSources = RecordingSources.muted
    private var microphoneStarted: TimeInterval = 0
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
               sessionMode: RecordingSessionMode = .conference, meetingOffset: TimeInterval = 0,
               segmenter: ContinuousRecordingSegmenter? = nil) async throws {
        try await start(sources: RecordingSources(mode: mode), directory: root, sessionMode: sessionMode, meetingOffset: meetingOffset, segmenter: segmenter)
    }

    func start(sources: RecordingSources, directory root: URL,
               sessionMode: RecordingSessionMode = .conference, meetingOffset: TimeInterval = 0,
               segmenter: ContinuousRecordingSegmenter? = nil) async throws {
        guard state == .idle else { throw MeetingRecorderError.message("已有录音正在进行。") }
        state = .preparing
        sessionID = UUID()
        activeSources = sources
        do {
            if sources.microphone {
                try Self.requireMicrophone()
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw MeetingRecorderError.message("请在系统设置 → 隐私与安全性 → 麦克风中允许录音。")
                }
            }
            // 先获取系统录音权限和目标，避免系统权限失败后留下正在录制的麦克风。
            var filter: SCContentFilter?
            if sources.systemAudio {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    throw MeetingRecorderError.message("没有可用显示器，无法采集系统声音。")
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let captureID = UUID()
            let directory = root.appendingPathComponent(captureID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard meetingOffset.isFinite, meetingOffset >= 0 else { throw BalancedAudioError.invalidManifest }
            try BalancedAudioIO.save(CanonicalCaptureContext(mode: sessionMode, meetingOffset: meetingOffset), to: directory.appendingPathComponent("capture-context.json"))
            self.directory = directory
            segmenter?.bindCanonicalArchive(directory)
            failure = nil
            canRetryMicrophone = false
            pausedAt = nil
            pausedDuration = 0
            started = MeetingCaptureTimeline.now
            recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "正在本地录音")
            let mode: MeetingRecordingMode = sources.microphone ? (sources.systemAudio ? .meeting : .microphone) : .systemAudio
            let sink = MeetingAudioSink(directory: directory, started: started, mode: mode, sessionMode: sessionMode, segmenter: segmenter, onAudio: onAudio, canonicalRecordingID: captureID) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.state == .preparing || self.state == .recording || self.state == .paused else { return }
                    self.reportFailure(error)
                }
            }
            self.sink = sink
            if sources.isMuted { sink.setSources(.muted, at: started) }
            if let filter {
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let delegate = makeSystemDelegate()
                let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                self.stream = stream
                systemDelegate = delegate
                try await stream.startCapture()
                if let error = delegate.lastError { throw error }
            }
            if sources.microphone {
                try startMicrophoneCapture(sink: sink)
            }
            if let failure { throw failure }
            state = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.state == .recording, self.activeSources.microphone,
                       CaptureHealth.microphoneStalled(started: self.microphoneStarted, lastFrame: self.sink?.lastFrame(for: .microphone), now: MeetingCaptureTimeline.now) {
                        self.canRetryMicrophone = true
                        self.reportFailure(MeetingRecorderError.microphoneStalled)
                    }
                    if self.state == .recording { self.sink?.advance(to: MeetingCaptureTimeline.now) }
                    self.onUpdate?(self.seconds, self.state == .paused || self.activeSources.isMuted ? 0 : self.sink?.level ?? 0)
                }
            }
        } catch {
            removeConfigurationObserver()
            if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
            engine = nil
            if let stream { try? await stream.stopCapture() }
            stream = nil
            systemDelegate = nil
            activeSources = .muted
            sink?.finish()
            sink = nil
            if let recordingActivity { ProcessInfo.processInfo.endActivity(recordingActivity) }
            recordingActivity = nil
            state = .idle
            throw error
        }
    }

    private func makeSystemDelegate() -> MeetingSystemAudioDelegate {
        let session = sessionID
        return MeetingSystemAudioDelegate { [weak self] source, error in
            Task { @MainActor in
                guard let self, self.sessionID == session, self.stream === source,
                      self.activeSources.systemAudio, self.state == .recording || self.state == .paused else { return }
                self.reportFailure(error)
            }
        }
    }

    /// Enabling prepares the new source before committing; a failed permission
    /// request leaves the old sources running. Stopping invalidates this work.
    func toggleSource(_ kind: MeetingAudioTrack.Kind) async throws {
        guard (state == .recording || state == .paused), sourceSwitchID == nil, failure == nil, let sink else {
            throw MeetingRecorderError.message("当前无法切换录音音源。")
        }
        let session = sessionID, operation = UUID()
        sourceSwitchID = operation
        defer { if sourceSwitchID == operation { sourceSwitchID = nil } }
        let target = activeSources.toggling(kind)
        func checkSession() throws {
            guard sessionID == session, sourceSwitchID == operation,
                  state == .recording || state == .paused else { throw CancellationError() }
        }
        if target.contains(kind) {
            if kind == .microphone {
                try Self.requireMicrophone()
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try checkSession()
                guard allowed else { throw MeetingRecorderError.message("请在系统设置 → 隐私与安全性 → 麦克风中允许录音。") }
                try startMicrophoneCapture(sink: sink)
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try checkSession()
                guard let display = content.displays.first else { throw MeetingRecorderError.message("没有可用显示器，无法采集系统声音。") }
                let config = SCStreamConfiguration()
                config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000; config.channelCount = 2
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let delegate = makeSystemDelegate()
                let candidate = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: delegate)
                try candidate.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                do {
                    try await candidate.startCapture(); try checkSession()
                    if let error = delegate.lastError { throw error }
                }
                catch { try? await candidate.stopCapture(); throw error }
                stream = candidate; systemDelegate = delegate
            }
            activeSources = target
            sink.setSources(target)
        } else {
            // Gate callbacks before releasing hardware. Delayed buffers are
            // clipped at this boundary and cannot leak into a muted interval.
            activeSources = target
            sink.setSources(target)
            if kind == .microphone {
                removeConfigurationObserver()
                if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
                engine = nil
            } else {
                let previous = stream
                stream = nil; systemDelegate = nil
                if let previous {
                    do { try await previous.stopCapture() }
                    catch {
                        try checkSession()
                        throw MeetingRecorderError.message("系统声音已关闭，但停止系统采集时发生错误：\(error.localizedDescription)")
                    }
                }
                try checkSession()
            }
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

    func resumeAfterDraining() async -> Bool {
        guard state == .paused, let sink else { return false }
        let session = sessionID
        do { try await sink.prepareToResume() }
        catch { failure = error; onError?(error); return false }
        guard state == .paused, sessionID == session else { return false }
        return resume()
    }

    private func startMicrophoneCapture(sink: MeetingAudioSink) throws {
        try Self.requireMicrophone()
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
            microphoneStarted = MeetingCaptureTimeline.now
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            throw error
        }
        let engineID = ObjectIdentifier(engine)
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording, self.activeSources.microphone,
                      let activeEngine = self.engine, ObjectIdentifier(activeEngine) == engineID else { return }
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
        sessionID = UUID(); sourceSwitchID = nil
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
        systemDelegate = nil
        self.sink = nil
        defer {
            if let recordingActivity { ProcessInfo.processInfo.endActivity(recordingActivity) }
            recordingActivity = nil
            state = .idle
            activeSources = .muted
        }
        let destination = try await Task.detached(priority: .utility) { try sink.finishCanonical(duration: duration) }.value
        let manifest = try JSONDecoder().decode(BalancedRecordingManifest.self, from: Data(contentsOf: destination))
        let captureWarning = (failure ?? stopFailure ?? sink.recordingError)?.localizedDescription
        return MeetingRecording(audioURL: destination,
                                microphoneURL: manifest.streams.contains { $0.streamID == "microphone" } ? directory.appendingPathComponent("microphone/final.manifest.json") : nil,
                                systemAudioURL: manifest.streams.contains { $0.streamID == "system" } ? directory.appendingPathComponent("system/final.manifest.json") : nil,
                                seconds: Double(manifest.durationFrames) / 16_000, warning: captureWarning)
    }
}

struct MeetingAudioTrack: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case microphone, system }
    let kind: Kind
    let url: URL
    let offset: TimeInterval
}

/// Per-stream errors are delivered only while that stream belongs to the active
/// session. Expected stops and failed candidate streams never poison the sink.
private final class MeetingSystemAudioDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    var lastError: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
    let onError: (SCStream, Error) -> Void
    init(onError: @escaping (SCStream, Error) -> Void) { self.onError = onError }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); storedError = error; lock.unlock()
        onError(stream, error)
    }
}

/// 麦克风 hostTime 与 ScreenCaptureKit PTS 都使用 CoreMedia host clock；禁止用回调抵达时间对齐。
struct MeetingCaptureTimeline {
    static var now: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
    let started: TimeInterval
    private var pauses: [Range<TimeInterval>] = []
    private var pauseStart: TimeInterval?

    init(started: TimeInterval) { self.started = started }
    func position(at timestamp: TimeInterval) -> TimeInterval {
        let removed = pauses.reduce(0.0) { $0 + max(0, min(timestamp, $1.upperBound) - $1.lowerBound) }
            + (pauseStart.map { max(0, timestamp - $0) } ?? 0)
        return max(0, timestamp - started - removed)
    }

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
    private let canonicalRecordingID: UUID?
    private var canonicalWriters: [MeetingAudioTrack.Kind: MacSegmentedSourceWriter] = [:]
    private var enabledSources: RecordingSources
    private var declaredSources: [CanonicalSourceDeclaration] = []
    private var tracks: [MeetingAudioTrack] = []
    private var finished = false
    private var failed = false
    private var storedError: Error?
    var recordingError: Error? { queue.sync { storedError } }
    private var meter: Float = 0
    private var timeline: MeetingCaptureTimeline
    private var sourceTimeline: RecordingSourceTimeline
    private var hasIntentionalSilence = false
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
         onAudio: (([Float]) -> Void)? = nil, canonicalRecordingID: UUID? = nil, onError: @escaping (Error) -> Void) {
        self.directory = directory
        self.timeline = MeetingCaptureTimeline(started: started)
        self.sourceTimeline = RecordingSourceTimeline(started: started, sources: RecordingSources(mode: mode))
        self.onError = onError
        self.canonicalRecordingID = canonicalRecordingID
        self.enabledSources = RecordingSources(mode: mode)
        let activeSegmenter = sessionMode == .continuous ? segmenter : nil
        self.segmenter = activeSegmenter
        if onAudio != nil || activeSegmenter != nil {
            live = MeetingLiveAudioMixer(trackCount: mode == .meeting ? 2 : 1) { samples, offset in
                onAudio?(samples)
                activeSegmenter?.append(samples, at: offset)
            }
        }
        super.init()
        if canonicalRecordingID != nil {
            do { try declareSources(enabledSources, frame: 0) } catch { report(error) }
        }
    }

    func setSources(_ sources: RecordingSources, at timestamp: TimeInterval = MeetingCaptureTimeline.now) {
        queue.sync {
            sourceTimeline.setSources(sources, at: timestamp)
            enabledSources = sources
            if canonicalRecordingID != nil {
                do { try declareSources(sources, frame: Int64((timeline.position(at: timestamp) * 16_000).rounded())) }
                catch { report(error) }
            }
            live?.setTrackCount((sources.microphone ? 1 : 0) + (sources.systemAudio ? 1 : 0))
            hasIntentionalSilence = hasIntentionalSilence || sources.isMuted
            healthLock.lock(); meter = 0; healthLock.unlock()
            do { try JSONEncoder().encode(sourceTimeline.events).write(to: directory.appendingPathComponent("sources.json"), options: .atomic) }
            catch { report(error) }
        }
    }

    /// Keeps the ASR/continuous-segment clock moving through intentional mute,
    /// without waiting for either hardware source to deliver its next frame.
    func advance(to timestamp: TimeInterval) {
        queue.async {
            guard !self.finished, !self.failed, !self.livePaused else { return }
            let slices = self.timeline.slices(at: timestamp, frames: 1, sampleRate: 16_000)
            if let offset = slices.first?.offset {
                self.live?.advance(to: offset)
                if self.canonicalRecordingID != nil {
                    do {
                        if self.enabledSources.isMuted, self.canonicalWriters.isEmpty {
                            _ = try self.canonicalWriter(.microphone, startFrame: 0)
                        }
                        let frame = Int64((offset * 16_000).rounded())
                        for (kind, writer) in self.canonicalWriters where !self.enabledSources.contains(kind) {
                            try writer.appendSilence(untilFrame: frame)
                        }
                    } catch { self.report(error) }
                }
            }
        }
    }

    func setPaused(_ value: Bool, at timestamp: TimeInterval = MeetingCaptureTimeline.now) {
        queue.sync {
            timeline.setPaused(value, at: timestamp)
            livePaused = value
            do { for writer in canonicalWriters.values { if value { try writer.pause() } else { try writer.resume() } } }
            catch { report(error) }
            healthLock.lock(); meter = 0; healthLock.unlock()
        }
        if value {
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.livePaused, !self.finished else { return }
                self.live?.flush()
            }
        }
    }

    func prepareToResume() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    for writer in self.canonicalWriters.values { try writer.resume() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
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

    func appendSystemAudio(_ buffer: AVAudioPCMBuffer, at timestamp: TimeInterval) {
        guard let copy = Self.copy(buffer, frames: 0..<Int(buffer.frameLength)) else { return }
        queue.async { self.write(copy, kind: .system, at: timestamp) }
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
        for range in sourceTimeline.slices(kind: kind, at: timestamp, frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate) {
            guard let allowed = Self.copy(buffer, frames: range) else { continue }
            writeAllowed(allowed, kind: kind, at: timestamp + Double(range.lowerBound) / buffer.format.sampleRate)
        }
    }

    private func writeAllowed(_ buffer: AVAudioPCMBuffer, kind: MeetingAudioTrack.Kind, at timestamp: TimeInterval) {
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
        if canonicalRecordingID != nil {
            do {
                let writer = try canonicalWriter(kind, startFrame: Int64((offset * 16_000).rounded()))
                try writer.append(buffer, offset: offset)
                if let channels = buffer.floatChannelData {
                    var peak: Float = 0
                    for channel in 0..<(buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)) {
                        let count = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
                        for index in 0..<count { let sample = abs(channels[channel][index]); if sample.isFinite { peak = max(peak, sample) } }
                    }
                    healthLock.lock(); meter = min(1, max(peak, meter)); healthLock.unlock()
                }
            } catch { report(error) }
            return
        }
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

    private func canonicalWriter(_ kind: MeetingAudioTrack.Kind, startFrame: Int64) throws -> MacSegmentedSourceWriter {
        if let existing = canonicalWriters[kind] { return existing }
        guard let canonicalRecordingID else { throw BalancedAudioError.invalidManifest }
        let streamID = kind == .microphone ? "microphone" : "system"
        let writer = try MacSegmentedSourceWriter(directory: directory.appendingPathComponent(streamID), recordingID: canonicalRecordingID,
                                                streamID: streamID, startFrame: startFrame) { [weak self] item in
            self?.queue.async { [weak self] in self?.publishSealed(item) }
        }
        canonicalWriters[kind] = writer
        return writer
    }
    private func declareSources(_ sources: RecordingSources, frame: Int64) throws {
        for kind in [MeetingAudioTrack.Kind.microphone, .system] where sources.contains(kind) {
            let id = kind == .microphone ? "microphone" : "system"
            if !declaredSources.contains(where: { $0.streamID == id }) { declaredSources.append(CanonicalSourceDeclaration(streamID: id, startFrame: frame)) }
        }
        try BalancedAudioIO.save(declaredSources, to: directory.appendingPathComponent("canonical-sources.json"))
    }

    private func publishSealed(_ item: ResilientRecordingSegmentDescriptor) {
        do {
            let url = directory.appendingPathComponent("playback.manifest.json")
            var head = FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode(BalancedPlaybackHead.self, from: Data(contentsOf: url))
                : BalancedPlaybackHead(recordingID: item.recordingID)
            if let index = head.streams.firstIndex(where: { $0.streamID == item.streamID }) {
                if item.index < head.streams[index].segmentCount { return }
                guard item.index == head.streams[index].segmentCount, item.startFrame == head.streams[index].endFrame else { throw BalancedAudioError.invalidManifest }
                head.streams[index].segmentCount += 1; head.streams[index].endFrame += item.validFrames; head.streams[index].byteCount += item.byteCount
            } else {
                guard item.index == 0 else { throw BalancedAudioError.invalidManifest }
                head.streams.append(BalancedPlaybackStreamHead(streamID: item.streamID, startFrame: item.startFrame,
                    endFrame: item.startFrame + item.validFrames, segmentCount: 1, byteCount: item.byteCount))
            }
            try head.validate(); try BalancedAudioIO.save(head, to: url)
        } catch { report(error) }
    }

    func finishCanonical(duration: TimeInterval) throws -> URL {
        try queue.sync {
            guard let canonicalRecordingID, duration.isFinite, duration > 0 else { throw BalancedAudioError.invalidManifest }
            if canonicalWriters.isEmpty, hasIntentionalSilence { _ = try canonicalWriter(.microphone, startFrame: 0) }
            guard !canonicalWriters.isEmpty else { throw MeetingRecorderError.message("未采集到音频，请检查系统权限和输入设备。") }
            var manifests: [URL] = []
            for writer in canonicalWriters.values { manifests.append(try writer.finish(untilFrame: Int64((duration * 16_000).rounded()))) }
            for (kind, resampler) in resamplers {
                let tail = try resampler.finish(); live?.append(tail.samples, kind: kind, offset: tail.offset)
            }
            live?.flush(); live = nil; resamplers.removeAll(); finished = true
            return try MacSegmentedManifest.finalize(recordingID: canonicalRecordingID, root: directory, trackManifests: manifests)
        }
    }

    @discardableResult func finish(duration: TimeInterval? = nil) -> [MeetingAudioTrack] {
        queue.sync {
            if canonicalRecordingID != nil {
                for writer in canonicalWriters.values { do { try writer.pause() } catch { report(error) } }
                live?.flush(); live = nil; resamplers.removeAll(); finished = true
                return []
            }
            if tracks.isEmpty, hasIntentionalSilence, let duration, duration > 0 {
                // A deliberately muted session is a valid silent recording;
                // a session with unavailable hardware still fails as before.
                let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                var remaining = Int((duration * 16_000).rounded())
                var offset = 0
                while remaining > 0, !failed {
                    let count = min(8192, remaining)
                    let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                    silence.frameLength = AVAudioFrameCount(count)
                    memset(silence.floatChannelData![0], 0, count * MemoryLayout<Float>.size)
                    writeActive(silence, kind: .microphone, offset: Double(offset) / 16_000)
                    offset += count; remaining -= count
                }
            }
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
    private var gain: Float
    private let onAudio: ([Float], TimeInterval) -> Void
    var bufferedFrames: Int { min(capacity, max(0, latest - cursor)) }

    init(trackCount: Int, onAudio: @escaping ([Float], TimeInterval) -> Void) {
        gain = 0.9 / Float(max(1, trackCount))
        self.onAudio = onAudio
    }

    func setTrackCount(_ count: Int) {
        let next: Float = 0.9 / Float(max(1, count))
        guard next != gain else { return }
        let scale = next / gain
        for index in ring.indices { ring[index] *= scale }
        gain = next
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

    func advance(to offset: TimeInterval) {
        guard offset.isFinite, offset >= 0 else { return }
        latest = max(latest, Int((offset * 16_000).rounded()))
        emit(until: max(cursor, latest - holdback))
    }

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
