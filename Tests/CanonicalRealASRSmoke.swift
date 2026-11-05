import Foundation
import AVFoundation

@main struct CanonicalRealASRSmoke {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
        let id = UUID(), capture = base.appendingPathComponent("Capture"), root = capture.appendingPathComponent(id.uuidString)
        let source = try MacSegmentedSourceWriter(directory: root.appendingPathComponent("microphone"), recordingID: id, streamID: "microphone", startFrame: 0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else { fatalError("buffer") }
        var frames: AVAudioFramePosition = 0
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { fatalError("empty input") }
            if CommandLine.arguments.contains("--quiet"), let channels = buffer.floatChannelData {
                for c in 0..<Int(buffer.format.channelCount) { for i in 0..<Int(buffer.frameLength) { channels[c][i] *= 0.05 } }
            }
            try source.append(buffer, offset: Double(frames) / input.processingFormat.sampleRate)
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        let partial = try source.finish(), manifest = try MacSegmentedManifest.finalize(recordingID: id, root: root, trackManifests: [partial])
        let audio: URL
        if CommandLine.arguments.contains("--range") {
            let final = try CanonicalAudioReader(manifestURL: manifest), ranges = capture.appendingPathComponent("Segments")
            try FileManager.default.createDirectory(at: ranges, withIntermediateDirectories: true)
            audio = ranges.appendingPathComponent("test-range.json")
            try JSONEncoder().encode(CanonicalAudioRange(sourceRecordingID: id, startFrame: 16_000, endFrame: final.durationFrames)).write(to: audio)
        } else { audio = manifest }
        let temporary = base.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let engine = TranscriptionEngine(temporaryRoot: temporary), model = URL(fileURLWithPath: CommandLine.arguments[3]), executable = URL(fileURLWithPath: CommandLine.arguments[4])
        let output = try engine.transcribe(audio: audio, model: model, executable: executable, language: "zh", hotwords: ["产品"], context: "产品会议", offlineWindows:true)
        guard output.text.contains("录音"), output.text.contains("会议") else { fatalError("Unexpected synthetic transcript: \(output.text)") }
        print("REAL_ASR_TEXT=\(output.text)")
        let rows = try engine.analyzeSpeakers(audio: audio, model: model, executable: executable, transcript: output, language: "zh")
        guard rows.map({ $0.separator + $0.text }).joined() == output.text else { fatalError("Speaker alignment changed transcript") }
        print("REAL_SPEAKER_ROWS=\(rows.count)")
    }
}
