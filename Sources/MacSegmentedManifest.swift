import Foundation
import Darwin

/// Finalizes independently persisted microphone/system tracks without
/// re-encoding or moving their source segments.
enum MacSegmentedManifest {
    private struct Binding: Decodable {
        let recordingID: UUID
        let streamID: String
        let startFrame: Int64
    }

    /// Finish interrupted tracks without reopening the microphone or system
    /// capture. An existing completed track is reused; a busy lock propagates
    /// to the caller so it can retry asynchronously after the encoder drains.
    static func recoverAndFinalize(recordingID: UUID, root: URL) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var partials: [URL] = []
        for streamID in ["microphone", "system"] {
            let directory = root.appendingPathComponent(streamID, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard directory.standardizedFileURL.resolvingSymlinksInPath().path == directory.path else { throw BalancedAudioError.integrityFailure }
            let bindingURL = directory.appendingPathComponent("stream.json")
            guard bindingURL.resolvingSymlinksInPath().path == bindingURL.path,
                  let size = try FileManager.default.attributesOfItem(atPath: bindingURL.path)[.size] as? NSNumber,
                  size.int64Value > 0, size.int64Value <= 65_536 else { throw BalancedAudioError.invalidManifest }
            let binding = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: bindingURL))
            guard binding.recordingID == recordingID, binding.streamID == streamID, binding.startFrame >= 0 else { throw BalancedAudioError.identityConflict }
            let session = try ResilientRecordingSession(directory: directory, id: recordingID)
            let state = try ResilientRecordingSession.inspect(directory: directory)
            guard state.unreadableIndices.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            if state.storedState == .finished {
                partials.append(directory.appendingPathComponent("final.manifest.json"))
            } else {
                try session.configureSealedOutput(streamID: streamID, streamStartFrame: binding.startFrame) { _ in }
                partials.append(try session.finishSegments())
            }
        }
        return try finalize(recordingID: recordingID, root: root, trackManifests: partials)
    }

    static func finalize(recordingID: UUID, root: URL, trackManifests: [URL]) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard !trackManifests.isEmpty, trackManifests.count <= 2 else { throw BalancedAudioError.invalidManifest }
        var streams: [BalancedAudioStream] = []
        for location in trackManifests {
            let path = location.standardizedFileURL.resolvingSymlinksInPath()
            let folder = path.deletingLastPathComponent()
            guard folder.deletingLastPathComponent().path == root.path, path.lastPathComponent == "final.manifest.json",
                  let size = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber,
                  size.int64Value > 0, size.int64Value <= 32 * 1024 * 1024 else { throw BalancedAudioError.invalidManifest }
            let partial = try JSONDecoder().decode(BalancedRecordingManifest.self, from: Data(contentsOf: path))
            try partial.validate()
            guard partial.recordingID == recordingID, partial.streams.count == 1,
                  let stream = partial.streams.first, stream.streamID == folder.lastPathComponent,
                  ["microphone", "system"].contains(stream.streamID) else { throw BalancedAudioError.identityConflict }
            for segment in stream.segments {
                let file = folder.appendingPathComponent(segment.filename).standardizedFileURL.resolvingSymlinksInPath()
                guard file.deletingLastPathComponent().path == folder.path else { throw BalancedAudioError.integrityFailure }
                try BalancedAudioIO.validateFile(file, segment: segment, decode: false)
            }
            streams.append(stream)
        }
        let manifest = BalancedRecordingManifest(recordingID: recordingID, streams: streams)
        let data = try manifest.canonicalData(), destination = root.appendingPathComponent("final.manifest.json")
        guard destination.standardizedFileURL.resolvingSymlinksInPath().path == destination.path else { throw BalancedAudioError.integrityFailure }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else { throw BalancedAudioError.identityConflict }
        } else { try data.write(to: destination, options: .atomic) }
        let file = try FileHandle(forWritingTo: destination); try file.synchronize(); try file.close()
        let fd = open(root.path, O_RDONLY); guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }
}
