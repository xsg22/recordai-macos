import Foundation
import AVFoundation

@MainActor final class MacLibraryAudioAdapter: LibraryAudioAdapter {
    private let library: MeetingLibrary
    init(library: MeetingLibrary) { self.library = library }
    func automaticCandidates(userId: UUID) throws -> [LibraryAudioCandidate] {
        guard library.activeSyncUserId == userId else { throw LibraryAudioError.invalid }
        let records = try library.list()
        guard library.warnings.isEmpty else { throw LibraryAudioError.invalid }
        return try records.filter { $0.userId == userId && $0.syncContent != nil && $0.status != .recording && $0.status != .transcribing }.map {
            LibraryAudioCandidate(recordingId:$0.id,revision:try LibraryAudioCandidate.revision(library.audioURLs(for:$0)))
        }
    }
    private func record(_ id: UUID, _ userId: UUID) throws -> MeetingRecord {
        guard library.activeSyncUserId == userId else { throw LibraryAudioError.invalid }
        let r = try library.load(id)
        guard r.userId == userId,r.syncContent != nil,r.status != .recording,r.status != .transcribing else { throw LibraryAudioError.invalid };return r
    }
    func sources(_ id: UUID, userId: UUID) async throws -> [LibraryAudioSource] {
        let r = try record(id,userId),urls = try library.audioURLs(for:r)
        // Cloud clients receive ordinary, verified M4A files. Local capture
        // references and immutable source segments remain untouched.
        var sources: [LibraryAudioSource] = [];var offset = 0
        var originals = Set<URL>()
        for input in urls {
            let original = try CanonicalAudioInput.originalManifest(for: input)
            guard originals.insert(original).inserted else { continue }
            let url: URL
            var captureStart: Int?
            if original.lastPathComponent == "final.manifest.json" {
                if let context = try CanonicalCaptureContext.read(original.deletingLastPathComponent()) {
                    guard let ms = LibrarySyncCodec.milliseconds(context.meetingOffset) else { throw LibraryAudioError.invalid }
                    captureStart = ms
                }
                let cache = library.directory(for:id).appendingPathComponent("AudioExports",isDirectory:true)
                try LibraryAudioFiles.directory(cache)
                let export = Task.detached(priority:.utility) {
                    let reader = try CanonicalAudioReader(manifestURL:original)
                    guard let manifest = reader.manifest else { throw LibraryAudioError.invalid }
                    return try CanonicalAudioExport.prepare(manifestURL:original,recordingID:manifest.recordingID,
                        cacheRoot:cache,isCancelled:{ Task.isCancelled })
                }
                url = try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
            } else { url = original }
            let duration = try await AVURLAsset(url:url).load(.duration);_ = try record(id,userId)
            guard let ms = LibrarySyncCodec.milliseconds(duration.seconds),ms > 0 else { throw LibraryAudioError.invalid }
            var start = captureStart ?? offset
            if let archive = r.syncedAudio,let i = archive.filenames.firstIndex(of:url.lastPathComponent),archive.manifest.parts.indices.contains(i) { start = archive.manifest.parts[i].timelineStartMs }
            sources.append(LibraryAudioSource(url:url,durationMs:ms,timelineStartMs:start));offset = start+ms
        }
        let latest = try record(id,userId)
        guard latest.audioFiles == r.audioFiles,latest.audioDurations == r.audioDurations else { throw LibraryAudioError.changed }
        return sources
    }
    func install(_ manifest: LibraryAudioManifest, files: [URL], userId: UUID) async throws {
        let initial = try record(manifest.recordingId,userId)
        guard initial.status == .completed,initial.pendingAudioFiles.isEmpty else { throw LibraryAudioError.invalid }
        try LibraryAudioFiles.validate(manifest,id:manifest.recordingId)
        guard files.count == manifest.parts.count else { throw LibraryAudioError.invalid }
        var names: [String] = []
        for (part,file) in zip(manifest.parts,files) {
            let name = "synced-\(part.id.uuidString.lowercased()).\(part.fileExtension)"
            let target = library.directory(for:manifest.recordingId).appendingPathComponent("Audio").appendingPathComponent(name)
            try LibraryAudioFiles.install(file,at:target,part:part)
            let duration = try await AVURLAsset(url:target).load(.duration);_ = try record(manifest.recordingId,userId)
            guard duration.seconds.isFinite,duration.seconds > 0 else { throw LibraryAudioError.invalid };names.append(name)
        }
        var latest = try record(manifest.recordingId,userId)
        guard latest.status == initial.status,latest.pendingAudioFiles.isEmpty,latest.audioFiles == initial.audioFiles,latest.audioDurations == initial.audioDurations else { throw LibraryAudioError.changed }
        // Switch references atomically only after every original was checked. Existing files stay intact.
        latest.audioFiles = names;latest.audioDurations = Dictionary(uniqueKeysWithValues:zip(names,manifest.parts).map { ($0.0,Double($0.1.durationMs)/1000) })
        latest.syncedAudio = LibraryAudioArchive(manifest:manifest,filenames:names)
        for i in latest.transcriptParagraphs.indices {
            guard let start = latest.transcriptParagraphs[i].start,
                  let index = manifest.parts.indices.last(where: { Double(manifest.parts[$0].timelineStartMs)/1000 <= start }) else { continue }
            latest.transcriptParagraphs[i].audioFile = names[index];latest.transcriptParagraphs[i].localStart = start-Double(manifest.parts[index].timelineStartMs)/1000
        }
        _ = try library.save(latest)
    }
}
