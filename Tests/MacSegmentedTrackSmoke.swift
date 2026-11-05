import Foundation
import AVFoundation

@main struct TrackSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID(), directory = root.appendingPathComponent(id.uuidString)
        do {
            let first = try MacSegmentedTrackWriter(directory: directory, recordingID: id, streamID: "microphone", startFrame: 3_200)
            try first.append([Float](repeating: 0.2, count: 16_000), startFrame: 3_200)
            try first.append([Float](repeating: 0.4, count: 8_000), startFrame: 27_200)
            try first.pause()
        }
        do {
            var reopened: MacSegmentedTrackWriter?
            for _ in 0..<500 {
                do { reopened = try MacSegmentedTrackWriter(directory: directory, recordingID: id, streamID: "microphone", startFrame: 3_200); break }
                catch let error as CocoaError where error.code == .fileWriteFileExists { Thread.sleep(forTimeInterval: 0.01) }
            }
            guard let second = reopened else { throw CocoaError(.fileWriteFileExists) }
            try second.append([Float](repeating: 0.6, count: 16_000), startFrame: 35_200)
            let url = try second.finish()
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let stream = (object["streams"] as! [[String: Any]])[0]
            let segments = stream["segments"] as! [[String: Any]]
            precondition(stream["startFrame"] as! Int == 3_200)
            precondition(segments.reduce(0) { $0 + ($1["validFrames"] as! Int) } == 48_000)
            print("PASS: resumed offset track retains timeline gap and 48000 frames")
        }
        try FileManager.default.removeItem(at: directory)
        let systemID = UUID(), systemDirectory = root.appendingPathComponent(systemID.uuidString)
        do {
            let source = try MacSegmentedSourceWriter(directory: systemDirectory, recordingID: systemID, streamID: "system", startFrame: 0)
            let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 48_000)!; buffer.frameLength = 48_000
            for frame in 0..<48_000 { buffer.floatChannelData![0][frame] = 0.2; buffer.floatChannelData![1][frame] = 0.2 }
            try source.append(buffer, offset: 0)
            try source.append(buffer, offset: 2) // One second of missing input is silence.
            try source.pause(); try source.resume(); try source.append(buffer, offset: 3)
            let url = try source.finish()
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let stream = (json["streams"] as! [[String: Any]])[0]
            let segments = stream["segments"] as! [[String: Any]]
            precondition(segments.reduce(0) { $0 + ($1["validFrames"] as! Int) } == 64_000)
            var samples: [Float] = []
            for index in segments.indices {
                let file = try AVAudioFile(forReading: systemDirectory.appendingPathComponent(String(format: "%08d.m4a", index)))
                let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: chunk)
                samples.append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength)))
            }
            precondition(samples.count == 64_000)
            let level: (Range<Int>) -> Float = { range in range.reduce(0) { $0 + abs(samples[$1]) } / Float(range.count) }
            precondition(level(4_000..<12_000) > 0.1 && level(20_000..<28_000) < 0.01 && level(52_000..<60_000) > 0.1)
            print("PASS: 48k stereo resampled to 16k mono with gaps and pause/resume")
        }
        try FileManager.default.removeItem(at: systemDirectory)
    }
}
