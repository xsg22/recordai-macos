import Foundation
import AVFoundation

/// Exercises the same sink and library registration used by the recording UI.
/// Synthetic PCM only; this never requests microphone or screen permission.
@main struct MacCanonicalCaptureSmoke {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let library = try MeetingLibrary(root: root.appendingPathComponent("Library"))
        var record = MeetingRecord(title: "Canonical fixture", text: "Preserve existing words", notes: "Preserve notes", status: .recording)
        record = try library.save(record)
        let session = UUID(), capture = library.directory(for: record.id).appendingPathComponent("Capture/" + session.uuidString)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let sink = MeetingAudioSink(directory: capture, started: 1000, mode: .meeting,
                                    canonicalRecordingID: session) { _ in }
        func audio(rate: Double, channels: AVAudioChannelCount, frequency: Double) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!; buffer.frameLength = buffer.frameCapacity
            for channel in 0..<Int(channels) {
                for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 2 * .pi * frequency / rate) * 0.2) }
            }
            return buffer
        }
        let microphone = audio(rate: 16_000, channels: 1, frequency: 440)
        let system = audio(rate: 48_000, channels: 2, frequency: 880)
        sink.appendMicrophone(microphone, at: 1000); sink.appendSystemAudio(system, at: 1000)
        sink.setPaused(true, at: 1001); sink.setPaused(false, at: 1002)
        sink.appendMicrophone(microphone, at: 1002); sink.appendSystemAudio(system, at: 1002)
        sink.setSources(.muted, at: 1003); sink.advance(to: 1003.5)
        sink.setPaused(true, at: 1003.5)
        let final = try sink.finishCanonical(duration: 2.5)
        let manifest = try JSONDecoder().decode(BalancedRecordingManifest.self, from: Data(contentsOf: final)); try manifest.validate()
        precondition(manifest.recordingID == session && manifest.durationFrames == 40_000 && manifest.streams.count == 2)
        var hashes: [URL: String] = [:]
        for stream in manifest.streams {
            for segment in stream.segments {
                let url = capture.appendingPathComponent(stream.streamID + "/" + segment.filename)
                try BalancedAudioIO.validateFile(url, segment: segment); hashes[url] = segment.sha256
            }
        }
        precondition(!FileManager.default.fileExists(atPath: capture.appendingPathComponent("meeting.m4a").path))
        let registered = try library.importAudio(final, into: &record, recordingDuration: 2.5, captureSession: session)
        precondition(registered == final && record.audioFiles.count == 1 && record.pendingAudioFiles == record.audioFiles)
        precondition(record.duration == 2.5 && record.text == "Preserve existing words" && record.notes == "Preserve notes")
        let reopened = try library.load(record.id)
        let paths = try library.audioURLs(for: reopened); precondition(paths == [final])
        _ = try library.importAudio(final, into: &record, recordingDuration: 2.5, captureSession: session)
        precondition(record.audioFiles.count == 1 && record.duration == 2.5)
        for (url, hash) in hashes { let current = try BalancedAudioIO.hashFile(url).1; precondition(current == hash) }
        let reader = try CanonicalAudioReader(manifestURL: paths[0])
        let silence = try reader.read(startFrame: 36_000, count: 4000)
        precondition((0..<Int(silence.frameLength)).allSatisfy { abs(silence.floatChannelData![0][$0]) < 0.00001 })
        precondition(!FileManager.default.fileExists(atPath: library.directory(for: record.id).appendingPathComponent("Audio").path))
        let chapterDirectory = capture.deletingLastPathComponent().appendingPathComponent("Segments")
        try FileManager.default.createDirectory(at: chapterDirectory, withIntermediateDirectories: true)
        let chapter = chapterDirectory.appendingPathComponent("chapter.json")
        try BalancedAudioIO.save(CanonicalAudioRange(sourceRecordingID: session, startFrame: 8000, endFrame: 24000), to: chapter)
        let view = try CanonicalAudioInput.reader(for: chapter)!
        precondition(view.durationFrames == 16000 && view.manifest == nil)
        let reference = try reader.read(startFrame: 8000, count: 4096), actual = try view.read(startFrame: 0, count: 4096)
        precondition((0..<4096).allSatisfy { reference.floatChannelData![0][$0] == actual.floatChannelData![0][$0] })
        _ = sink.recordingError
        let savedFinal = capture.appendingPathComponent("saved-final.json")
        try FileManager.default.moveItem(at: final, to: savedFinal)
        do {
            let headURL = capture.appendingPathComponent("playback.manifest.json"), completeHead = try Data(contentsOf: headURL)
            var missingSource = try JSONDecoder().decode(BalancedPlaybackHead.self, from: completeHead)
            missingSource.streams.removeAll { $0.streamID == "system" }
            try BalancedAudioIO.save(missingSource, to: headURL)
            do { _ = try CanonicalAudioInput.reader(for: chapter); preconditionFailure("Late enabled source must block range ASR") }
            catch CanonicalAudioInput.Failure.notReady { }
            try completeHead.write(to: headURL, options: .atomic)
            let liveView = try CanonicalAudioInput.reader(for: chapter)!
            let actual = try liveView.read(startFrame: 0, count: 4096)
            precondition((0..<4096).allSatisfy { reference.floatChannelData![0][$0] == actual.floatChannelData![0][$0] })
        } catch { try FileManager.default.moveItem(at: savedFinal, to: final); throw error }
        try FileManager.default.moveItem(at: savedFinal, to: final)
        let segmenter = ContinuousRecordingSegmenter(directory: chapterDirectory,
            policy: ContinuousSegmentPolicy(maximumSeconds: 0.5, minimumSeconds: 0.1, trailingSilenceSeconds: 0.1)) { _ in }
        segmenter.bindCanonicalArchive(capture)
        for index in 0..<10 { segmenter.append([Float](repeating: 0.2, count: 1600), at: Double(index) / 10) }
        let chapters = segmenter.finish(); precondition(chapters.count == 2)
        for chapter in chapters {
            precondition(chapter.url.pathExtension == "json")
            let reader = try CanonicalAudioInput.reader(for: chapter.url)!
            precondition(reader.durationFrames == 8000)
        }
        let artifacts = try FileManager.default.contentsOfDirectory(at: chapterDirectory, includingPropertiesForKeys: nil)
        precondition(artifacts.allSatisfy { $0.pathExtension == "json" })
        let waveform = try await AudioWaveformStore(directory: root.appendingPathComponent("Waveforms")).load(final)
        precondition(waveform.duration == 2.5 && waveform.peaks.contains { $0 > 0.05 })
        let destination = try MeetingAudioExport.prepare(audio: paths + chapters.map(\.url), parent: root, recordingID: record.id, cacheRoot: root.appendingPathComponent("ExportCache"))
        let exported = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        precondition(exported.count == 1 && exported[0].pathExtension == "m4a")
        let exportedAudio = try AVAudioFile(forReading: exported[0]); precondition(exportedAudio.length == 40_000)
        var manualPlayer: MeetingAudioPlayer?
        let state = AppState(storageURL: root.appendingPathComponent("Library"), connectionNamespace: "canonical-fixture-" + UUID().uuidString,
            speechModelStore: ASRModelStore(root: root.appendingPathComponent("Models"), manifest: nil), playbackFactory: { url in
                let player = try MeetingAudioPlayer(contentsOf: url, manualRendering: true); manualPlayer = player; return player
            })
        state.select(record.id)
        precondition(state.canPlayCurrentRecording && state.playbackDuration == 2.5)
        state.togglePlayback(); precondition(state.playing && manualPlayer != nil)
        _ = try manualPlayer!.renderForTesting(frames: 4096)
        state.seek(1.25); precondition(abs(state.playbackTime - 1.25) < 0.0001)
        state.togglePlayback(); precondition(!state.playing)
        state.stopPlayback(); precondition(!state.playing && state.playbackTime == 0)
        let recoveryID = UUID(), pending = library.directory(for: record.id).appendingPathComponent("Capture/" + recoveryID.uuidString)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        do {
            let interrupted = MeetingAudioSink(directory: pending, started: 1000, canonicalRecordingID: recoveryID) { _ in }
            interrupted.appendMicrophone(microphone, at: 1000); interrupted.setPaused(true, at: 1001)
            _ = interrupted.finish()
        }
        let scan = try CaptureRecovery.scan(meetingID: record.id, meetingDirectory: library.directory(for: record.id),
            managedAudio: paths, importedSessions: record.importedCaptureSessions)
        guard let candidate = scan.candidates.first(where: { $0.id == recoveryID }) else { preconditionFailure("Interrupted canonical capture was not discovered") }
        precondition(candidate.canonical && candidate.duration == 1)
        let recovered = try await CaptureRecovery.finalizeCanonical(candidate)
        _ = try library.importAudio(recovered, into: &record, recordingDuration: 1, captureSession: recoveryID)
        precondition(record.audioFiles.count == 2 && record.duration == 3.5)
        // A crash may leave a closed chapter plus an unregistered tail. Recovery
        // must retain both, preserve the source, and be idempotent on retry.
        var continuous = MeetingRecord(title: "Interrupted continuous fixture", text: "Keep edited transcript", status: .interrupted)
        continuous.recordingSessionMode = .continuous; continuous.duration = 37
        continuous = try library.save(continuous)
        let interruptedID = UUID(), interruptedRoot = library.directory(for: continuous.id).appendingPathComponent("Capture/" + interruptedID.uuidString)
        let queueRoot = interruptedRoot.deletingLastPathComponent().appendingPathComponent("Segments")
        try FileManager.default.createDirectory(at: interruptedRoot, withIntermediateDirectories: true)
        try BalancedAudioIO.save(CanonicalCaptureContext(mode: .continuous, meetingOffset: 37), to: interruptedRoot.appendingPathComponent("capture-context.json"))
        do {
            let interrupted = MeetingAudioSink(directory: interruptedRoot, started: 1000, canonicalRecordingID: interruptedID) { _ in }
            interrupted.appendMicrophone(microphone, at: 1000); interrupted.setPaused(true, at: 1001); _ = interrupted.finish()
        }
        let closed = ContinuousRecordingSegmenter(directory: queueRoot,
            policy: ContinuousSegmentPolicy(maximumSeconds: 0.5, minimumSeconds: 0.1, trailingSilenceSeconds: 0.1), timelineOffset: 37) { _ in }
        closed.bindCanonicalArchive(interruptedRoot)
        closed.append([Float](repeating: 0.2, count: 8000), at: 0)
        let oldChapters = closed.finish(); precondition(oldChapters.count == 1 && oldChapters[0].start == 37)
        _ = try library.importAudio(oldChapters[0].url, into: &continuous, recordingDuration: 0.5,
            captureSession: oldChapters[0].id, timelineEnd: 37.5)
        continuous.continuousSegmentFiles.append(continuous.importedCaptureSessions[oldChapters[0].id.uuidString]!)
        continuous = try library.save(continuous)
        let recoveryState = AppState(storageURL: root.appendingPathComponent("Library"), connectionNamespace: "recovery-fixture-" + UUID().uuidString,
            speechModelStore: ASRModelStore(root: root.appendingPathComponent("NoModels"), manifest: nil), captureStarter: { recorder, request in
                try await recorder.start(sources: .muted, directory: request.directory, sessionMode: request.sessionMode,
                    meetingOffset: request.meetingOffset, segmenter: request.segmenter)
            })
        recoveryState.recordingMode = .systemAudio // the injected starter uses muted PCM, with no physical microphone
        recoveryState.select(continuous.id); recoveryState.findRecoverableAudio()
        for _ in 0..<500 where recoveryState.recoveryBusy { try await Task.sleep(for: .milliseconds(20)) }
        let continuousCandidate = recoveryState.recoveryCandidates.first { $0.id == interruptedID }!
        recoveryState.recoverCapture(continuousCandidate)
        for _ in 0..<500 where recoveryState.recoveryBusy { try await Task.sleep(for: .milliseconds(20)) }
        let recoveredContinuous = try library.load(continuous.id)
        precondition(recoveredContinuous.duration == 38 && recoveredContinuous.pendingAudioFiles.count == 2)
        precondition(recoveredContinuous.audioFiles.count == 3 && recoveredContinuous.text == "Keep edited transcript")
        let fullSourceKey = recoveredContinuous.importedCaptureSessions[interruptedID.uuidString]!
        precondition(!recoveredContinuous.pendingAudioFiles.contains(fullSourceKey))
        let restoredQueue = try ContinuousRecordingQueue.load(queueRoot)
        precondition(restoredQueue.count == 2 && restoredQueue.map(\.start) == [37, 37.5])
        let savedQueue = restoredQueue.map(\.id)
        recoveryState.recoverCapture(continuousCandidate)
        for _ in 0..<500 where recoveryState.recoveryBusy { try await Task.sleep(for: .milliseconds(20)) }
        let repeatedRecord = try library.load(continuous.id)
        precondition(repeatedRecord.audioFiles == recoveredContinuous.audioFiles && repeatedRecord.duration == recoveredContinuous.duration && repeatedRecord.pendingAudioFiles == recoveredContinuous.pendingAudioFiles)
        let repeatedQueue = try ContinuousRecordingQueue.load(queueRoot)
        precondition(repeatedQueue.map(\.id) == savedQueue)
        recoveryState.recoverCapture(continuousCandidate, continueAfterSaving: true)
        for _ in 0..<500 where !recoveryState.recording { try await Task.sleep(for: .milliseconds(20)) }
        precondition(recoveryState.recording && recoveryState.current?.id == continuous.id && recoveryState.activeRecordingSessionMode == .continuous, "recording=\(recoveryState.recording) mode=\(String(describing:recoveryState.activeRecordingSessionMode)) status=\(recoveryState.status) error=\(String(describing:recoveryState.error)) recovery=\(recoveryState.recoveryStatus)")
        try await Task.sleep(for: .milliseconds(400))
        recoveryState.toggleRecording()
        for _ in 0..<500 where recoveryState.preparing { try await Task.sleep(for: .milliseconds(20)) }
        let afterContinue = try library.load(continuous.id)
        precondition(!recoveryState.recording && afterContinue.duration > 38 && afterContinue.audioFiles.count == 4)
        precondition(afterContinue.pendingAudioFiles == recoveredContinuous.pendingAudioFiles && afterContinue.text == recoveredContinuous.text)
        print("PASS: actual AppState recovery→continue→finish preserves pending ASR, meeting identity, transcript and duration without installed models (muted source)")
        var conference = MeetingRecord(title: "Interrupted conference fixture", text: "", status: .interrupted)
        conference = try library.save(conference)
        let conferenceID = UUID(), conferenceRoot = library.directory(for: conference.id).appendingPathComponent("Capture/" + conferenceID.uuidString)
        try FileManager.default.createDirectory(at: conferenceRoot, withIntermediateDirectories: true)
        do {
            let interrupted = MeetingAudioSink(directory: conferenceRoot, started: 1000, canonicalRecordingID: conferenceID) { _ in }
            interrupted.appendMicrophone(microphone, at: 1000); interrupted.setPaused(true, at: 1001); _ = interrupted.finish()
        }
        let conferenceState = AppState(storageURL: root.appendingPathComponent("Library"), connectionNamespace: "conference-fixture-" + UUID().uuidString,
            speechModelStore: ASRModelStore(root: root.appendingPathComponent("NoModels"), manifest: nil), captureStarter: { recorder, request in
                try await recorder.start(sources: .muted, directory: request.directory, sessionMode: request.sessionMode,
                    meetingOffset: request.meetingOffset, segmenter: request.segmenter)
            })
        conferenceState.recordingMode = .systemAudio
        conferenceState.select(conference.id); conferenceState.findRecoverableAudio()
        for _ in 0..<500 where conferenceState.recoveryBusy { try await Task.sleep(for: .milliseconds(20)) }
        let conferenceCandidate = conferenceState.recoveryCandidates.first { $0.id == conferenceID }!
        precondition(conferenceCandidate.canonical)
        conferenceState.continueRecording()
        for _ in 0..<500 where !conferenceState.recording { try await Task.sleep(for: .milliseconds(20)) }
        precondition(conferenceState.recording && conferenceState.activeRecordingSessionMode == .conference)
        try await Task.sleep(for: .milliseconds(400)); conferenceState.toggleRecording()
        for _ in 0..<500 where conferenceState.preparing { try await Task.sleep(for: .milliseconds(20)) }
        let afterConference = try library.load(conference.id)
        precondition(!conferenceState.recording && afterConference.duration > 1 && afterConference.pendingAudioFiles.count == 2 && afterConference.audioFiles.count == 2)
        print("PASS: actual AppState conference recovery→continue→finish accepts untranscribed originals and retains both sources (muted source)")
        // Simulate the next capture in the same meeting: the durable old queue
        // survives, chapter times append, and raw range frames stay capture-local.
        let nextID = UUID(), nextRoot = interruptedRoot.deletingLastPathComponent().appendingPathComponent(nextID.uuidString)
        let next = ContinuousRecordingSegmenter(directory: queueRoot,
            policy: ContinuousSegmentPolicy(maximumSeconds: 0.5, minimumSeconds: 0.1, trailingSilenceSeconds: 0.1), timelineOffset: 38) { _ in }
        next.bindCanonicalArchive(nextRoot); next.append([Float](repeating: 0.2, count: 8000), at: 0)
        let continuedQueue = next.finish()
        precondition(continuedQueue.count == 3 && continuedQueue.prefix(2).map(\.id) == savedQueue && continuedQueue[2].start == 38)
        let localRange = try JSONDecoder().decode(CanonicalAudioRange.self, from: Data(contentsOf: continuedQueue[2].url))
        precondition(localRange.startFrame == 0 && localRange.endFrame == 8000 && localRange.sourceRecordingID == nextID)
        print("PASS: actual AppState continuous crash recovery retains closed chapter, adds only uncovered tail, excludes full-source ASR, preserves edits; repeat recovery is idempotent")
        print("PASS: continued capture preserves durable queue and global chapter offsets without reindexing original AAC")
        let userID = UUID(); library.activeSyncUserId = userID
        func enrollFixture(_ value: MeetingRecord) throws -> MeetingRecord {
            var item = value; item.userId = userID; item.pendingAudioFiles = []; item.status = .completed
            item.syncContent = LibrarySyncRecording(id: item.id, title: item.title, createdAt: LibrarySyncCodec.date(item.created),
                durationMs: LibrarySyncCodec.milliseconds(item.duration), source: item.source.rawValue, language: item.language,
                isStarred: false, groupId: nil, speakers: [], paragraphs: [])
            return try library.save(item)
        }
        _ = try enrollFixture(library.load(record.id))
        let cloudAdapter = MacLibraryAudioAdapter(library: library)
        let canonicalSources = try await cloudAdapter.sources(record.id, userId:userID)
        precondition(canonicalSources.count == 2 && canonicalSources.allSatisfy { $0.url.pathExtension == "m4a" })
        precondition(canonicalSources.map(\.durationMs) == [2500,1000] && canonicalSources.map(\.timelineStartMs) == [0,2500])
        let canonicalAudio = try AVAudioFile(forReading:canonicalSources[0].url)
        precondition(canonicalAudio.length == 40_000)
        for (url,hash) in hashes { let current = try BalancedAudioIO.hashFile(url).1; precondition(current == hash) }
        let preservedArchive = try library.load(record.id); precondition(preservedArchive.audioFiles.first?.hasSuffix(".aacarchive") == true)
        var legacyCloud = MeetingRecord(title: "Legacy cloud fixture", text: "", status: .completed)
        _ = try library.importAudio(exported[0], into: &legacyCloud, recordingDuration: 2.5)
        legacyCloud = try enrollFixture(legacyCloud)
        let legacySources = try await cloudAdapter.sources(legacyCloud.id, userId: userID)
        precondition(legacySources.count == 1 && legacySources[0].durationMs == 2500)
        let parts = try legacySources.map { try LibraryAudioFiles.describe($0, recordingId: legacyCloud.id) }
        try LibraryAudioFiles.validate(LibraryAudioManifest(recordingId: legacyCloud.id, version: 1, parts: parts), id: legacyCloud.id)
        let legacyHash = try BalancedAudioIO.hashFile(exported[0]).1
        precondition(parts[0].sha256 == legacyHash)
        print("PASS: canonical cloud sources are verified complete M4A; original archive references and AAC hashes retained; legacy sources remain valid")
        print("PASS: production sink:48k stereo/system +16k mic, pause/resume/mute,40000 exact frames, no mixed master")
        print("PASS: actual library registers canonical archive in place, survives reopen, deduplicates registration, preserves edits and AAC hashes")
        print("PASS: actual canonical waveform, explicit compatible export and interrupted-capture recovery registration")
        print("PASS: actual AppState selects canonical archive and plays/seeks/pauses using injected offline renderer")
    }
}
