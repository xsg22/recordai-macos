import Foundation
import AVFoundation
import Darwin

/// Accelerated synthetic input, never a microphone or a battery/endurance claim.
@main struct MacCanonicalLongCaptureSmoke {
    final class Seals: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var invalid = false
        func receive(_ item: ResilientRecordingSegmentDescriptor) {
            lock.lock()
            let expected = counts[item.streamID, default: 0]
            invalid = invalid || item.index != expected || item.startFrame != Int64(expected) * 160_000 || item.validFrames != 160_000
            counts[item.streamID] = expected + 1
            lock.unlock(); ready.signal()
        }
        func check() {
            lock.lock(); defer { lock.unlock() }
            precondition(!invalid && counts["microphone"] == 4320 && counts["system"] == 4320)
        }
    }
    static func rss() -> Int64 { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Int64(usage.ru_maxrss) }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), id = UUID(), seals = Seals(), started = Date()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func open(_ stream: String) async throws -> MacSegmentedSourceWriter {
            for attempt in 0..<100 {
                do { return try MacSegmentedSourceWriter(directory: root.appendingPathComponent(stream), recordingID: id,
                    streamID: stream, startFrame: 0, onSealed: seals.receive) }
                catch let error as CocoaError where error.code == .fileWriteFileExists && attempt < 99 {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            throw CocoaError(.fileWriteFileExists)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000)!; pcm.frameLength = 160_000
        var microphone: MacSegmentedSourceWriter? = try await open("microphone")
        var system: MacSegmentedSourceWriter? = try await open("system")
        var baseline: Int64 = 0
        for index in 0..<4320 {
            try autoreleasepool {
                for frame in 0..<160_000 {
                    pcm.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * Double(300 + index % 400) / 16_000) * 0.2)
                }
                try microphone!.append(pcm, offset: Double(index) * 10)
                try system!.append(pcm, offset: Double(index) * 10)
            }
            precondition(seals.ready.wait(timeout: .now() + 30) == .success)
            precondition(seals.ready.wait(timeout: .now() + 30) == .success)
            if index == 31 { baseline = rss() }
            if index == 2159 {
                try microphone!.pause(); try system!.pause(); microphone = nil; system = nil
                microphone = try await open("microphone"); system = try await open("system")
                print("PASS: both production source writers reopened at six hours")
            }
            if index % 720 == 719 { print("Encoded dual-stream hours:", (index + 1) / 360) }
        }
        seals.check()
        let micManifest = try microphone!.finish(untilFrame: 691_200_000)
        let sysManifest = try system!.finish(untilFrame: 691_200_000)
        let final = try MacSegmentedManifest.finalize(recordingID: id, root: root, trackManifests: [micManifest, sysManifest])
        let manifest = try JSONDecoder().decode(BalancedRecordingManifest.self, from: Data(contentsOf: final)); try manifest.validate()
        precondition(manifest.durationFrames == 691_200_000 && manifest.streams.count == 2 && manifest.segmentCount == 8640)
        var inodes = Set<UInt64>()
        for stream in manifest.streams {
            for segment in stream.segments {
                try autoreleasepool {
                    let url = root.appendingPathComponent(stream.streamID + "/" + segment.filename)
                    try BalancedAudioIO.validateFile(url, segment: segment)
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    inodes.insert((attributes[.systemFileNumber] as! NSNumber).uint64Value)
                }
            }
        }
        precondition(inodes.count == 8640)
        let reader = try CanonicalAudioReader(manifestURL: final)
        for position: Int64 in [0, 345_590_000, 345_610_000, 691_199_000] {
            let buffer = try reader.read(startFrame: position, count: 1000)
            precondition(buffer.frameLength == 1000 && (0..<1000).contains { abs(buffer.floatChannelData![0][$0]) > 0.05 })
        }
        let growth = rss() - baseline; precondition(growth < 192 * 1024 * 1024)
        let report: [String: Any] = ["kind": "accelerated-synthetic-dual-source", "streams": 2, "segments": 8640,
            "validFramesPerStream": manifest.durationFrames, "aacBytes": manifest.byteCount,
            "independentInodes": inodes.count, "peakRSSGrowthBytes": growth,
            "elapsedSeconds": Date().timeIntervalSince(started), "physicalEndurance": false, "batteryMeasured": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        print("PASS: twelve hours per source, exact frame/hash/decode checks, independent AAC assets and boundary seeks", report)
    }
}
