import Foundation

enum MeetingAudioExport {
    static func prepare(audio: [URL], parent: URL, recordingID: UUID, cacheRoot: URL,
                        cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) throws -> URL {
        guard !audio.isEmpty else { throw MeetingLibraryError.missingAudio }
        // Chapters are views of a capture. Export its original archive once,
        // rather than duplicating every chapter or sharing metadata as audio.
        var originals: [URL] = []
        for url in audio {
            let source = try CanonicalAudioInput.originalManifest(for: url)
            if !originals.contains(source) { originals.append(source) }
        }
        let fm = FileManager.default
        let temporary = parent.appendingPathComponent(".cohear-export-" + UUID().uuidString)
        let destination = parent.appendingPathComponent("录音-" + recordingID.uuidString + "-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        var lastPercent = -1
        for (index, url) in originals.enumerated() {
            if cancelled() { throw CancellationError() }
            let source: URL
            if url.lastPathComponent == "final.manifest.json" {
                let manifest = try JSONDecoder().decode(BalancedRecordingManifest.self, from: Data(contentsOf: url))
                source = try CanonicalAudioExport.prepare(manifestURL: url, recordingID: manifest.recordingID, cacheRoot: cacheRoot,
                    isCancelled: cancelled, progress: { value in
                        let total = (Double(index) + value) / Double(originals.count), percent = Int(total * 100)
                        if percent != lastPercent { lastPercent = percent; progress(total) }
                    })
            } else { source = url }
            let filename = String(format: "%02d", index + 1) + "-" + (source == url ? source.lastPathComponent : "recording.m4a")
            try fm.copyItem(at: source, to: temporary.appendingPathComponent(filename))
        }
        if cancelled() { throw CancellationError() }
        try fm.moveItem(at: temporary, to: destination); progress(1)
        return destination
    }
}
