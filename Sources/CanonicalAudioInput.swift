import Foundation

/// Business chapters reference the original capture; they contain no audio.
struct CanonicalAudioRange: Codable {
    var kind = "talktuck-canonical-range-v1"
    let sourceRecordingID: UUID
    let startFrame: Int64
    let endFrame: Int64
}
struct CanonicalSourceDeclaration: Codable {
    let streamID: String
    let startFrame: Int64
}

enum CanonicalAudioInput {
    enum Failure: Error { case notReady, invalidReference }
    static func originalManifest(for url: URL) throws -> URL {
        guard url.pathExtension == "json", url.lastPathComponent != "final.manifest.json" else { return url }
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue <= 65_536 else { throw Failure.invalidReference }
        let range = try JSONDecoder().decode(CanonicalAudioRange.self, from: Data(contentsOf: url))
        guard range.kind == "talktuck-canonical-range-v1", try reader(for: url) != nil else { throw Failure.invalidReference }
        let parent = url.deletingLastPathComponent()
        let capture:URL
        if parent.lastPathComponent == "Audio" { capture=parent.deletingLastPathComponent().appendingPathComponent("Capture") }
        else if parent.deletingLastPathComponent().lastPathComponent == "Progressive" { capture=parent.deletingLastPathComponent().deletingLastPathComponent() }
        else { capture=parent.deletingLastPathComponent() }
        let final = capture.appendingPathComponent(range.sourceRecordingID.uuidString).appendingPathComponent("final.manifest.json")
        guard FileManager.default.fileExists(atPath: final.path) else { throw Failure.notReady }
        return final
    }
    static func reader(for url: URL) throws -> CanonicalAudioReader? {
        if url.lastPathComponent == "final.manifest.json" { return try CanonicalAudioReader(manifestURL: url) }
        guard url.pathExtension == "json" else { return nil }
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.int64Value > 0, size.int64Value <= 65_536 else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["kind"] as? String == "talktuck-canonical-range-v1" else { return nil }
        let range = try JSONDecoder().decode(CanonicalAudioRange.self, from: data)
        guard range.startFrame >= 0, range.endFrame > range.startFrame,
              range.endFrame - range.startFrame <= 600 * 16_000,
              range.endFrame <= BalancedAudioSegment.maximumTimelineFrames else { throw Failure.invalidReference }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let capture: URL
        if parent.lastPathComponent == "Audio" { capture = parent.deletingLastPathComponent().appendingPathComponent("Capture") }
        else if parent.lastPathComponent == "Segments", parent.deletingLastPathComponent().lastPathComponent == "Capture" { capture = parent.deletingLastPathComponent() }
        else if parent.lastPathComponent == range.sourceRecordingID.uuidString,
                parent.deletingLastPathComponent().lastPathComponent == "Progressive",
                parent.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Capture" {
            capture=parent.deletingLastPathComponent().deletingLastPathComponent()
        }
        else { throw Failure.invalidReference }
        let root = capture.appendingPathComponent(range.sourceRecordingID.uuidString)
        guard root.resolvingSymlinksInPath().path == root.path else { throw Failure.invalidReference }
        let final = root.appendingPathComponent("final.manifest.json"), head = root.appendingPathComponent("playback.manifest.json")
        var streams: [BalancedAudioStream] = []
        if FileManager.default.fileExists(atPath: final.path) {
            let full = try CanonicalAudioReader(manifestURL: final)
            guard let manifest = full.manifest, manifest.recordingID == range.sourceRecordingID,
                  range.endFrame <= manifest.durationFrames else { throw Failure.invalidReference }
            for stream in manifest.streams {
                let selected = stream.segments.filter { $0.endFrame > range.startFrame && $0.startFrame < range.endFrame }
                let parts = selected.isEmpty ? [stream.segments[0]] : selected
                streams.append(BalancedAudioStream(streamID: stream.streamID, startFrame: parts[0].startFrame, segments: parts))
            }
        } else {
            guard FileManager.default.fileExists(atPath: head.path) else { throw Failure.notReady }
            guard head.resolvingSymlinksInPath().path == head.path,
                  let size = try FileManager.default.attributesOfItem(atPath: head.path)[.size] as? NSNumber,
                  size.intValue > 0, size.intValue <= 16_384 else { throw Failure.invalidReference }
            let value = try JSONDecoder().decode(BalancedPlaybackHead.self, from: Data(contentsOf: head)); try value.validate()
            guard value.recordingID == range.sourceRecordingID else { throw Failure.invalidReference }
            let declared = try JSONDecoder().decode([CanonicalSourceDeclaration].self,
                from: Data(contentsOf: root.appendingPathComponent("canonical-sources.json")))
            guard declared.count <= 8, declared.allSatisfy({ BalancedAudioSegment.validStream($0.streamID) && $0.startFrame >= 0 }) else { throw Failure.invalidReference }
            guard declared.filter({ $0.startFrame < range.endFrame }).allSatisfy({ source in
                value.streams.contains { $0.streamID == source.streamID && $0.endFrame >= range.endFrame }
            }) else { throw Failure.notReady }
            guard value.streams.allSatisfy({ $0.endFrame >= range.endFrame }) else { throw Failure.notReady }
            for stream in value.streams {
                func part(_ index: Int) throws -> BalancedAudioSegment {
                    let location = root.appendingPathComponent(stream.streamID).appendingPathComponent(String(format: "%08d.segment.json", index))
                    guard location.resolvingSymlinksInPath().path == location.path,
                          let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber,
                          size.intValue > 0, size.intValue <= 65_536 else { throw Failure.invalidReference }
                    let item = try JSONDecoder().decode(BalancedAudioSegment.self, from: Data(contentsOf: location))
                    guard item.index == index else { throw Failure.invalidReference }; return item
                }
                var low = 0, high = stream.segmentCount
                while low < high { let middle = (low + high) / 2; if try part(middle).endFrame <= range.startFrame { low = middle + 1 } else { high = middle } }
                var parts: [BalancedAudioSegment] = []
                for index in low..<stream.segmentCount {
                    let item = try part(index); if item.startFrame >= range.endFrame { break }; parts.append(item)
                    guard parts.count <= 128 else { throw Failure.invalidReference }
                }
                if parts.isEmpty { parts = [try part(0)] }
                streams.append(BalancedAudioStream(streamID: stream.streamID, startFrame: parts[0].startFrame, segments: parts))
            }
        }
        return try CanonicalAudioReader(root: root, recordingID: range.sourceRecordingID, streams: streams,
                                        startFrame: range.startFrame, endFrame: range.endFrame)
    }
}
