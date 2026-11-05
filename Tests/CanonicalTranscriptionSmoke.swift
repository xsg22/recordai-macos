import Foundation
import AVFoundation

@main struct CanonicalTranscriptionSmoke {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID(), capture = base.appendingPathComponent("Capture"), root = capture.appendingPathComponent(id.uuidString), bin = base.appendingPathComponent("bin"), models = base.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["Qwen3ASR", "Paraformer", "Sortformer", "QwenAligner"] {
            let folder = models.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if ["Sortformer", "QwenAligner"].contains(name) { try Data().write(to: folder.appendingPathComponent("model.safetensors")) }
        }
        for name in ["paraformer-live", "qwen-asr"] {
            let target = bin.appendingPathComponent(name)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        let mic = try MacSegmentedTrackWriter(directory: root.appendingPathComponent("microphone"), recordingID: id, streamID: "microphone", startFrame: 0)
        let system = try MacSegmentedTrackWriter(directory: root.appendingPathComponent("system"), recordingID: id, streamID: "system", startFrame: 16_000)
        try mic.append([Float](repeating: 0.25, count: 80_000), startFrame: 0)
        try system.append([Float](repeating: 0.1, count: 64_000), startFrame: 16_000)
        let manifest = try MacSegmentedManifest.finalize(recordingID: id, root: root, trackManifests: [try mic.finish(), try system.finish()])
        let temporary = base.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let engine = TranscriptionEngine(temporaryRoot: temporary), model = models.appendingPathComponent("Qwen3ASR"), executable = bin.appendingPathComponent("qwen-asr")
        let missing = base.appendingPathComponent("missing-storage")
        var missingRejected = false
        do { _ = try TranscriptionEngine(temporaryRoot: missing).transcribe(audio: manifest, model: model, executable: executable, language: "zh") }
        catch { missingRejected = true }
        precondition(missingRejected && !FileManager.default.fileExists(atPath: missing.path), "missing temporary storage must not be recreated")
        setenv("RECORD_AI_TRANSCRIPTION_TMP_ROOT", missing.path, 1)
        var environmentRejected = false
        do { _ = try TranscriptionEngine().transcribe(audio: manifest, model: model, executable: executable, language: "zh") }
        catch { environmentRejected = true }
        unsetenv("RECORD_AI_TRANSCRIPTION_TMP_ROOT")
        precondition(environmentRejected && !FileManager.default.fileExists(atPath: missing.path), "missing environment-configured storage must not be recreated")
        let output = try engine.transcribe(audio: manifest, model: model, executable: executable, language: "zh", hotwords: ["产品"], context: "产品背景")
        precondition(output.text == "你好\n世界" && output.paragraphs.count == 2)
        setenv("CANONICAL_VAD_EMPTY", "1", 1)
        let silence = try TranscriptionEngine(temporaryRoot: temporary).transcribe(audio: manifest, model: model, executable: executable, language: "zh")
        unsetenv("CANONICAL_VAD_EMPTY")
        precondition(silence.text.isEmpty && silence.paragraphs.isEmpty, "no speech should return an empty transcript")
        let ranges = capture.appendingPathComponent("Segments", isDirectory: true)
        try FileManager.default.createDirectory(at: ranges, withIntermediateDirectories: true)
        let range = ranges.appendingPathComponent("range.json")
        try JSONEncoder().encode(CanonicalAudioRange(sourceRecordingID: id, startFrame: 16_000, endFrame: 80_000)).write(to: range)
        let rangeOutput = try TranscriptionEngine(temporaryRoot: temporary).transcribe(audio: range, model: model, executable: executable, language: "zh", hotwords: ["产品"], context: "产品背景")
        precondition(rangeOutput.text == output.text && rangeOutput.paragraphs.first?.start == 0, "range recognition must use a relative timeline")
        let held = root.appendingPathComponent("held-final.json")
        let complete = try JSONDecoder().decode(BalancedRecordingManifest.self, from: Data(contentsOf: manifest))
        let headStreams = complete.streams.map { stream in
            BalancedPlaybackStreamHead(streamID: stream.streamID, startFrame: stream.startFrame, endFrame: stream.endFrame,
                                       segmentCount: stream.segments.count, byteCount: stream.segments.reduce(0) { $0 + $1.byteCount })
        }
        for stream in complete.streams {
            let folder = root.appendingPathComponent(stream.streamID)
            for segment in stream.segments {
                let persisted = folder.appendingPathComponent(String(format: "%08d.segment.json", segment.index))
                let stored = try JSONDecoder().decode(BalancedAudioSegment.self, from: Data(contentsOf: persisted))
                precondition(stored == segment)
            }
        }
        let declarations = complete.streams.map { CanonicalSourceDeclaration(streamID: $0.streamID, startFrame: $0.startFrame) }
        try JSONEncoder().encode(declarations).write(to: root.appendingPathComponent("canonical-sources.json"))
        let head = root.appendingPathComponent("playback.manifest.json")
        let partial = BalancedPlaybackHead(recordingID: id, streams: headStreams.filter { $0.streamID == "microphone" })
        try JSONEncoder().encode(partial).write(to: head, options: .atomic)
        let ready = try JSONEncoder().encode(BalancedPlaybackHead(recordingID: id, streams: headStreams))
        try FileManager.default.moveItem(at: manifest, to: held)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { try? ready.write(to: head, options: .atomic) }
        let waitingSince = Date()
        let pendingOutput = try TranscriptionEngine(temporaryRoot: temporary).transcribe(audio: range, model: model, executable: executable, language: "zh", hotwords: ["产品"], context: "产品背景")
        precondition(pendingOutput.text == output.text && Date().timeIntervalSince(waitingSince) >= 0.4, "range must wait for the missing declared source")
        try FileManager.default.removeItem(at: head)
        let waitingEngine = TranscriptionEngine(temporaryRoot: temporary), waitDone = DispatchSemaphore(value: 0), waitingCancelled = CancelledResult()
        DispatchQueue.global().async {
            do { _ = try waitingEngine.transcribe(audio: range, model: model, executable: executable, language: "zh", hotwords: ["产品"], context: "产品背景") }
            catch is CancellationError { waitingCancelled.setCancelled() }
            catch { }
            waitDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.4); waitingEngine.cancel()
        precondition(waitDone.wait(timeout: .now() + 3) == .success && waitingCancelled.cancelled, "waiting for a source segment must be cancellable")
        try FileManager.default.moveItem(at: held, to: manifest)
        let phases = PhaseRecorder()
        let rows = try engine.analyzeSpeakers(audio: manifest, model: model, executable: executable, transcript: output, language: "zh", onPhase: { phases.append($0) })
        precondition(rows.map { $0.separator + $0.text }.joined() == output.text && rows.allSatisfy { $0.speakerIDs == ["0"] })
        precondition(phases.values == [.diarizing, .aligning])
        let cancelledEngine = TranscriptionEngine(temporaryRoot: temporary), finished = DispatchSemaphore(value: 0)
        let result = CancelledResult()
        DispatchQueue.global().async {
            do { _ = try cancelledEngine.transcribe(audio: manifest, model: model, executable: executable, language: "zh", hotwords: ["产品"], context: "SLOW_TEST") }
            catch is CancellationError { result.setCancelled() }
            catch { }
            finished.signal()
        }
        Thread.sleep(forTimeInterval: 0.4); cancelledEngine.cancel()
        precondition(finished.wait(timeout: .now() + 5) == .success && result.cancelled, "cancellation must stop the streaming worker")
        let audioFile = root.appendingPathComponent("microphone/00000000.m4a")
        let handle = try FileHandle(forUpdating: audioFile); try handle.seek(toOffset: 32)
        let originalByte = try handle.read(upToCount: 1)!.first!; try handle.seek(toOffset: 32)
        try handle.write(contentsOf: Data([originalByte ^ 0xff])); try handle.close()
        var rejected = false
        do { _ = try TranscriptionEngine(temporaryRoot: temporary).transcribe(audio: manifest, model: model, executable: executable, language: "zh", hotwords: ["产品"], context: "产品背景") }
        catch { rejected = true }
        precondition(rejected, "changed audio must not be transcribed as valid")
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        precondition(temporaryFiles.isEmpty, "temporary ASR files must be removed after success, cancellation and errors")
        print("PASS: production canonical VAD/Qwen/speaker paths, PCM framing, hotwords, context, language and cancellation")
    }
}
private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock(); private var phases: [TranscriptPhase] = []
    func append(_ value: TranscriptPhase) { lock.lock(); phases.append(value); lock.unlock() }
    var values: [TranscriptPhase] { lock.lock(); defer { lock.unlock() }; return phases }
}
private final class CancelledResult: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func setCancelled() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
