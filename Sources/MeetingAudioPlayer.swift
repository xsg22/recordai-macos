import Foundation
import AVFoundation

/// A bounded player for both legacy audio files and canonical recordings.
/// All player-node bookkeeping is isolated to the main actor. The canonical
/// reader itself opens at most one file per source and reads small windows.
@MainActor final class MeetingAudioPlayer {
    private let legacy: AVAudioPlayer?
    private let reader: CanonicalAudioReader?
    private let engine: AVAudioEngine?
    private let node: AVAudioPlayerNode?
    private var nextFrame: Int64 = 0
    private var anchorFrame: Int64 = 0
    private var heldFrame: Int64 = 0
    private var scheduled = 0
    private var generation: UInt64 = 0
    private var active = false
    private var failed = false
    private let chunkFrames = 4096
    private let bufferLimit = 3
    private let manual: Bool
    /// Set before starting a canonical sentence; no samples after this point
    /// are scheduled. Legacy AVAudioPlayer still needs its caller's timer.
    var playbackEndTime: TimeInterval?
    private var limitFrame: Int64 {
        guard let reader else { return 0 }
        guard let end = playbackEndTime, end.isFinite else { return reader.durationFrames }
        return Int64((min(duration, max(0, end)) * 16_000).rounded(.down))
    }

    convenience init(contentsOf url: URL) throws { try self.init(contentsOf: url, manualRendering: false) }
    init(contentsOf url: URL, manualRendering: Bool) throws {
        manual = manualRendering
        let canonical = try CanonicalAudioInput.reader(for: url)
        if canonical == nil {
            guard !manualRendering else { throw CocoaError(.fileReadUnsupportedScheme) }
            legacy = try AVAudioPlayer(contentsOf: url); reader = nil; engine = nil; node = nil
        } else {
            let reader = canonical!
            let engine = AVAudioEngine(), node = AVAudioPlayerNode()
            engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: reader.format)
            if manualRendering {
                try engine.enableManualRenderingMode(.offline, format: reader.format, maximumFrameCount: 4096)
            }
            self.reader = reader; self.engine = engine; self.node = node; legacy = nil
        }
    }
    var duration: TimeInterval { legacy?.duration ?? Double(reader?.durationFrames ?? 0) / 16_000 }
    var currentTime: TimeInterval {
        get {
            if let legacy { return legacy.currentTime }
            guard let reader else { return 0 }
            var frame = heldFrame
            if active, let node, let render = node.lastRenderTime,
               render.isSampleTimeValid || render.isHostTimeValid,
               let time = node.playerTime(forNodeTime: render), time.isSampleTimeValid {
                frame = anchorFrame + max(0, time.sampleTime)
            }
            heldFrame = min(reader.durationFrames, max(0, frame))
            return Double(heldFrame) / 16_000
        }
        set {
            if let legacy { legacy.currentTime = newValue; return }
            guard let reader, newValue.isFinite else { return }
            let wasActive = active
            invalidateBuffers()
            heldFrame = min(reader.durationFrames, max(0, Int64((min(max(0, newValue), duration) * 16_000).rounded())))
            if wasActive { _ = play() }
        }
    }
    var volume: Float {
        get { legacy?.volume ?? node?.volume ?? 1 }
        set { if let legacy { legacy.volume = newValue } else { node?.volume = newValue } }
    }
    var isPlaying: Bool { legacy?.isPlaying ?? (active && engine?.isRunning == true && node?.isPlaying == true) }

    @discardableResult func play() -> Bool {
        if let legacy { return legacy.play() }
        guard reader != nil, let engine, let node, !failed else { return false }
        if active {
            if engine.isRunning && node.isPlaying { return true }
            heldFrame = Int64((currentTime * 16_000).rounded())
            invalidateBuffers()
        }
        do {
            if heldFrame >= limitFrame { heldFrame = 0; invalidateBuffers() }
            if scheduled == 0 {
                anchorFrame = heldFrame; nextFrame = heldFrame
                try refill()
            }
            guard scheduled > 0 else { return false }
            if !engine.isRunning { try engine.start() }
            active = true; node.play(); return true
        } catch { failed = true; invalidateBuffers(); return false }
    }
    func pause() {
        if let legacy { legacy.pause(); return }
        guard active else { return }
        heldFrame = Int64((currentTime * 16_000).rounded())
        node?.pause(); active = false
    }
    func stop() {
        if let legacy { legacy.stop(); return }
        invalidateBuffers(); heldFrame = 0; engine?.stop()
    }
    private func invalidateBuffers() {
        generation &+= 1; node?.stop(); scheduled = 0; active = false
    }
    private func refill() throws {
        guard let reader, let node else { return }
        let end = limitFrame
        while scheduled < bufferLimit && nextFrame < end {
            let buffer = try reader.read(startFrame: nextFrame, count: Int(min(Int64(chunkFrames), end - nextFrame)))
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            nextFrame += Int64(buffer.frameLength); scheduled += 1
            let token = generation
            node.scheduleBuffer(buffer, completionCallbackType: manual ? .dataRendered : .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in self?.bufferCompleted(token) }
            }
        }
    }
    private func bufferCompleted(_ token: UInt64) {
        guard token == generation, scheduled > 0, reader != nil else { return }
        scheduled -= 1
        do { try refill() }
        catch { failed = true; heldFrame = Int64((currentTime * 16_000).rounded()); invalidateBuffers(); return }
        if scheduled == 0 && nextFrame >= limitFrame {
            heldFrame = limitFrame; active = false; node?.stop()
        }
    }
    /// Test-only offline rendering; no microphone or physical output is used.
    func renderForTesting(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard manual, let engine, let reader, frames > 0, frames <= 4096,
              let output = AVAudioPCMBuffer(pcmFormat: reader.format, frameCapacity: frames) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let status = try engine.renderOffline(frames, to: output)
        guard status == .success else { throw CocoaError(.fileReadUnknown) }
        return output
    }
    func interruptEngineForTesting() { if manual { engine?.stop() } }
}
