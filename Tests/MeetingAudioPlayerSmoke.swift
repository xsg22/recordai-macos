import Foundation
import AVFoundation

@main struct MeetingAudioPlayerSmoke {
    @MainActor static func main() async throws {
        let id = UUID(), root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(id.uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try MacSegmentedTrackWriter(directory: root.appendingPathComponent("microphone"), recordingID: id, streamID: "microphone", startFrame: 0)
        let system = try MacSegmentedTrackWriter(directory: root.appendingPathComponent("system"), recordingID: id, streamID: "system", startFrame: 8_000)
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.07) * 0.3) }
        try mic.append(samples, startFrame: 0); try system.append(samples, startFrame: 8_000)
        let manifest = try MacSegmentedManifest.finalize(recordingID: id, root: root, trackManifests: [try mic.finish(), try system.finish()])
        let legacy = try MeetingAudioPlayer(contentsOf: root.appendingPathComponent("microphone/00000000.m4a"))
        precondition(legacy.duration > 0); legacy.currentTime = 0.5; legacy.volume = 0.5
        precondition(abs(legacy.currentTime - 0.5) < 0.001 && abs(legacy.volume - 0.5) < 0.001)
        legacy.stop()
        let player = try MeetingAudioPlayer(contentsOf: manifest, manualRendering: true)
        precondition(abs(player.duration - 3.5) < 0.001)
        precondition(player.play())
        let reference = try CanonicalAudioReader(manifestURL: manifest)
        let expected = try reference.read(startFrame: 0, count: 4096)
        let actual = try player.renderForTesting(frames: 4096)
        var error: Float = 0
        for i in 0..<Int(actual.frameLength) { error += abs(actual.floatChannelData![0][i] - expected.floatChannelData![0][i]) }
        precondition(error / Float(max(1, actual.frameLength)) < 0.01, "offline playback differs from canonical mix")
        await Task.yield()
        player.pause(); precondition(!player.isPlaying)
        precondition(player.play())
        let resumed = try player.renderForTesting(frames: 4096)
        let expectedResume = try reference.read(startFrame: 4096, count: 4096)
        var resumeError: Float = 0
        for i in 0..<Int(resumed.frameLength) { resumeError += abs(resumed.floatChannelData![0][i] - expectedResume.floatChannelData![0][i]) }
        precondition(resumeError / Float(max(1, resumed.frameLength)) < 0.01, "pause/resume skipped or repeated audio")
        let interruptedAt = Int64((player.currentTime * 16_000).rounded())
        player.interruptEngineForTesting(); precondition(!player.isPlaying)
        precondition(player.play())
        let restarted = try player.renderForTesting(frames: 4096)
        let expectedRestart = try reference.read(startFrame: interruptedAt, count: 4096)
        var restartError: Float = 0
        for i in 0..<Int(restarted.frameLength) { restartError += abs(restarted.floatChannelData![0][i] - expectedRestart.floatChannelData![0][i]) }
        precondition(restartError / Float(max(1, restarted.frameLength)) < 0.01, "engine restart did not resume from last observed position")
        player.pause()
        player.currentTime = 1.5; player.playbackEndTime = 2
        precondition(player.play())
        _ = try player.renderForTesting(frames: 4096)
        try await Task.sleep(for: .milliseconds(2))
        _ = try player.renderForTesting(frames: 3904)
        try await Task.sleep(for: .milliseconds(10))
        precondition(!player.isPlaying && abs(player.currentTime - 2) < 0.001, "sentence playback must stop at its boundary")
        player.playbackEndTime = nil
        player.currentTime = 1.5; precondition(abs(player.currentTime - 1.5) < 0.001)
        precondition(player.play())
        let afterSeek = try player.renderForTesting(frames: 4096)
        let expectedSeek = try reference.read(startFrame: 24_000, count: 4096)
        var seekError: Float = 0
        for i in 0..<Int(afterSeek.frameLength) { seekError += abs(afterSeek.floatChannelData![0][i] - expectedSeek.floatChannelData![0][i]) }
        precondition(seekError / Float(max(1, afterSeek.frameLength)) < 0.01, "seeked playback differs from canonical mix")
        var cursor: Int64 = 24_000 + Int64(afterSeek.frameLength)
        while cursor < reference.durationFrames {
            try await Task.sleep(for: .milliseconds(2))
            let count = AVAudioFrameCount(min(4096, reference.durationFrames - cursor))
            let output = try player.renderForTesting(frames: count)
            let expectedWindow = try reference.read(startFrame: cursor, count: Int(count))
            var difference: Float = 0
            for i in 0..<Int(count) { difference += abs(output.floatChannelData![0][i] - expectedWindow.floatChannelData![0][i]) }
            precondition(difference / Float(count) < 0.01, "cross-buffer or end-of-file playback differs from the reference")
            cursor += Int64(count)
        }
        try await Task.sleep(for: .milliseconds(10))
        precondition(!player.isPlaying && abs(player.currentTime - player.duration) < 0.001, "playback should stop at EOF")
        player.stop(); precondition(!player.isPlaying && player.currentTime == 0)
        print("PASS: offline dual-source playback, cross-buffer refill, EOF, pause and seek")
    }
}
