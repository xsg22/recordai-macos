import Foundation
import AVFoundation

@main struct MacSegmentedManifestSmoke {
    static func main() throws {
        let id = UUID(), root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent(id.uuidString)
        let mic = try MacSegmentedTrackWriter(directory: root.appendingPathComponent("microphone"), recordingID: id, streamID: "microphone", startFrame: 0)
        let system = try MacSegmentedTrackWriter(directory: root.appendingPathComponent("system"), recordingID: id, streamID: "system", startFrame: 8_000)
        try mic.append([Float](repeating: 0.4, count: 16_000), startFrame: 0)
        try system.append([Float](repeating: 0.2, count: 16_000), startFrame: 8_000)
        let tracks = [try mic.finish(), try system.finish()]
        let manifest = try MacSegmentedManifest.finalize(recordingID: id, root: root, trackManifests: tracks)
        let repeated = try MacSegmentedManifest.finalize(recordingID: id, root: root, trackManifests: tracks)
        precondition(repeated == manifest)
        let reader = try CanonicalAudioReader(manifestURL: manifest)
        precondition(reader.durationFrames == 24_000)
        let audio = try reader.read(startFrame: 0, count: 24_000)
        let data = audio.floatChannelData![0]
        func mean(_ range: Range<Int>) -> Float { range.reduce(0) { $0 + abs(data[$1]) } / Float(range.count) }
        precondition(mean(2_000..<6_000) > 0.14 && mean(10_000..<14_000) > 0.22 && mean(19_000..<23_000) > 0.07)
        let file = root.appendingPathComponent("microphone/00000000.m4a")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: file)
        do { _ = try MacSegmentedManifest.finalize(recordingID: id, root: root, trackManifests: tracks); fatalError("symlink destination was accepted") }
        catch { }
        try FileManager.default.removeItem(at: manifest)
        _ = try MacSegmentedManifest.finalize(recordingID: id, root: root, trackManifests: tracks)
        let handle = try FileHandle(forUpdating: file); try handle.seek(toOffset: 32)
        let byte = try handle.read(upToCount: 1)!.first!; try handle.seek(toOffset: 32)
        try handle.write(contentsOf: Data([byte ^ 0xff])); try handle.close()
        do { _ = try MacSegmentedManifest.finalize(recordingID: id, root: root, trackManifests: tracks); fatalError("changed segment was accepted") }
        catch { }
        print("PASS: two-source canonical manifest, common timeline playback, duplicate finalize and hash rejection")
        try FileManager.default.removeItem(at: root)
        let interruptedID = UUID(), interrupted = root.deletingLastPathComponent().appendingPathComponent(interruptedID.uuidString)
        do {
            let a = try MacSegmentedTrackWriter(directory: interrupted.appendingPathComponent("microphone"), recordingID: interruptedID, streamID: "microphone", startFrame: 0)
            let b = try MacSegmentedTrackWriter(directory: interrupted.appendingPathComponent("system"), recordingID: interruptedID, streamID: "system", startFrame: 8_000)
            try a.append([Float](repeating: 0.4, count: 16_000), startFrame: 0)
            try b.append([Float](repeating: 0.2, count: 16_000), startFrame: 8_000)
            _ = try a.finish() // A crash can occur after only one track finishes.
            try b.pause()
        }
        var recovered: URL?
        for _ in 0..<300 {
            do { recovered = try MacSegmentedManifest.recoverAndFinalize(recordingID: interruptedID, root: interrupted); break }
            catch let error as CocoaError where error.code == .fileWriteFileExists { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard let recovered else { throw CocoaError(.fileWriteFileExists) }
        let resumed = try CanonicalAudioReader(manifestURL: recovered)
        precondition(resumed.durationFrames == 24_000 && resumed.manifest?.streams.count == 2)
        print("PASS: finishing an interrupted dual-source session reuses the finished track and preserves both timelines")
        try FileManager.default.removeItem(at: interrupted)
    }
}
