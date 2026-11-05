import Foundation
import AVFoundation

/// Run against a disposable copy made by the regression runner, never the
/// live library. Verifies real existing archives without publishing their data.
@main struct ExistingArchiveReadSmoke {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let library = try MeetingLibrary(root:root)
        let directories = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("Meetings"),includingPropertiesForKeys:nil)
        var recordings = 0, archives = 0, totalFrames:Int64 = 0
        for directory in directories {
            guard let id = UUID(uuidString:directory.lastPathComponent) else { continue }
            let record = try library.load(id), before = try Data(contentsOf:directory.appendingPathComponent("meeting.json"))
            let urls = try library.audioURLs(for:record)
            let agent = try AgentDataPublisher.snapshot(record,libraryRoot:root)
            precondition(agent.audioFiles.map(\.path) == urls.map(\.path))
            precondition(agent.audioFiles.allSatisfy(\.available))
            for url in urls where url.lastPathComponent == "final.manifest.json" {
                let reader = try CanonicalAudioReader(manifestURL:url)
                guard let manifest = reader.manifest else { fatalError("Missing manifest") }
                var hashes:[URL:String] = [:]
                for stream in manifest.streams { for part in stream.segments {
                    let source = url.deletingLastPathComponent().appendingPathComponent(stream.streamID+"/"+part.filename)
                    try BalancedAudioIO.validateFile(source,segment:part)
                    hashes[source] = try BalancedAudioIO.hashFile(source).1
                } }
                let player = try MeetingAudioPlayer(contentsOf:url,manualRendering:true)
                precondition(abs(player.duration-Double(manifest.durationFrames)/16000)<0.001)
                for frame in [Int64(0),max(0,manifest.durationFrames/2-4096),max(0,manifest.durationFrames-4096)] {
                    player.currentTime = Double(frame)/16000;precondition(player.play())
                    let count = AVAudioFrameCount(min(4096,manifest.durationFrames-frame))
                    let actual = try player.renderForTesting(frames:count), expected = try reader.read(startFrame:frame,count:Int(count))
                    var error:Float = 0
                    for i in 0..<Int(actual.frameLength) { error += abs(actual.floatChannelData![0][i]-expected.floatChannelData![0][i]) }
                    precondition(error/Float(max(1,actual.frameLength))<0.01,"Existing archive playback differs from original")
                    player.pause()
                }
                player.stop()
                let exported = try CanonicalAudioExport.prepare(manifestURL:url,recordingID:manifest.recordingID,cacheRoot:root.appendingPathComponent("VerifiedExports"))
                let audio = try AVAudioFile(forReading:exported);precondition(audio.length == manifest.durationFrames)
                for (file,hash) in hashes { let current = try BalancedAudioIO.hashFile(file).1;precondition(current == hash) }
                archives += 1;totalFrames += manifest.durationFrames
            }
            let after = try Data(contentsOf:directory.appendingPathComponent("meeting.json"));precondition(before == after)
            recordings += 1
        }
        precondition(archives > 0)
        print("PASS: existing recordings=\(recordings) archives=\(archives) frames=\(totalFrames); verified original hashes, start/middle/end playback and complete M4A exports; metadata unchanged")
    }
}
