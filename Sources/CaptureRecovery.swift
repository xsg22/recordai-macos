import AVFoundation
import CryptoKit
import Foundation

struct CaptureRecoveryCandidate: Identifiable, Sendable {
    let id: UUID
    let meetingID: UUID
    let directory: URL
    let tracks: [MeetingAudioTrack]
    let existingMix: URL?
    let duration: Double
    let warnings: [String]
}
struct CaptureRecoveryScan: Sendable {
    var candidates: [CaptureRecoveryCandidate] = []
    var warnings: [String] = []
}

/// 只检查原轨，不修改manifest。合成及复制在后台完成，原始音频始终保留。
enum CaptureRecovery {
    static func scan(meetingID: UUID, meetingDirectory: URL, managedAudio: [URL], importedSessions: [String: String]) throws -> CaptureRecoveryScan {
        let fm = FileManager.default
        let base = meetingDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = base.appendingPathComponent("Capture")
        guard fm.fileExists(atPath: root.path) else { return CaptureRecoveryScan() }
        guard root.resolvingSymlinksInPath().path == root.path else { throw MeetingRecorderError.message("录音恢复目录指向其他位置，已拒绝读取。") }
        var result = CaptureRecoveryScan()
        var knownDigests: [URL: String] = [:]
        for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            guard let session = UUID(uuidString: entry.lastPathComponent), importedSessions[session.uuidString] == nil else { continue }
            do {
                let properties = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard properties.isDirectory == true, properties.isSymbolicLink == false else { throw MeetingRecorderError.message("原轨目录包含不安全的符号链接或不是目录。") }
                // Foundation枚举可能返回/private/var，而解析后的系统路径是/var；统一后再验证真实边界。
                let directory = entry.resolvingSymlinksInPath().standardizedFileURL
                guard directory.deletingLastPathComponent().path == root.path else { throw MeetingRecorderError.message("原轨目录超出会议范围。") }
                let manifest = directory.appendingPathComponent("recording.json")
                guard manifest.resolvingSymlinksInPath().path == manifest.path else { throw MeetingRecorderError.message("录音清单路径不安全。") }
                let manifestSize = try fm.attributesOfItem(atPath: manifest.path)[.size] as? NSNumber
                guard let manifestSize, manifestSize.intValue <= 65_536 else { throw MeetingRecorderError.message("录音清单过大或无法读取。") }
                let source = try JSONDecoder().decode([MeetingAudioTrack].self, from: Data(contentsOf: manifest))
                guard source.count <= 2, !source.isEmpty, Set(source.map(\.kind)).count == source.count else { throw MeetingRecorderError.message("录音轨道清单无效。") }
                var tracks: [MeetingAudioTrack] = [], warnings: [String] = []
                var duration: Double = 0
                for track in source {
                    let expected = directory.appendingPathComponent(track.kind == .microphone ? "microphone.caf" : "system.caf")
                    guard track.offset.isFinite, track.offset >= 0, track.url.isFileURL,
                          track.url.resolvingSymlinksInPath().path == expected.path, expected.resolvingSymlinksInPath().path == expected.path else {
                        throw MeetingRecorderError.message("录音轨道路径或时间偏移无效，未读取目录外文件。")
                    }
                    do {
                        let seconds = try audioDuration(expected)
                        tracks.append(MeetingAudioTrack(kind: track.kind, url: expected, offset: track.offset)); duration = max(duration, track.offset + seconds)
                    } catch { warnings.append("\(track.kind == .microphone ? "麦克风" : "系统声音")原轨不可读，恢复时将缺少该轨道。") }
                }
                let mix = directory.appendingPathComponent("meeting.m4a")
                var existingMix: URL?
                if fm.fileExists(atPath: mix.path) {
                    guard mix.resolvingSymlinksInPath().path == mix.path else { throw MeetingRecorderError.message("混音文件路径不安全。") }
                    if let seconds = try? audioDuration(mix) { existingMix = mix; duration = seconds; warnings = [] }
                }
                guard duration.isFinite, duration > 0, existingMix != nil || !tracks.isEmpty else {
                    throw MeetingRecorderError.message("没有可读取的音频，原轨仍保留。")
                }
                // 旧版未存session去重标记；只对同大小候选做完整摘要核对，不按时长猜测配对。
                if let existingMix {
                    let size = try fm.attributesOfItem(atPath: existingMix.path)[.size] as? NSNumber
                    let possible = managedAudio.filter { ((try? fm.attributesOfItem(atPath: $0.path)[.size]) as? NSNumber) == size }
                    if !possible.isEmpty {
                        let hash = try digest(existingMix)
                        var alreadyManaged = false
                        for audio in possible {
                            let known = try knownDigests[audio] ?? digest(audio)
                            knownDigests[audio] = known
                            if known == hash { alreadyManaged = true; break }
                        }
                        if alreadyManaged { continue }
                    }
                }
                result.candidates.append(CaptureRecoveryCandidate(id: session, meetingID: meetingID, directory: directory, tracks: tracks,
                    existingMix: existingMix, duration: duration, warnings: warnings))
            } catch is CancellationError { throw CancellationError() }
            catch { result.warnings.append("录音片段 \(session.uuidString.prefix(8))：\(error.localizedDescription)") }
        }
        return result
    }
    static func audioDuration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw MeetingRecorderError.message("音频为空。") }
        return duration
    }
    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { try Task.checkCancellation(); hash.update(data: block) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func prepare(_ candidate: CaptureRecoveryCandidate, destination: URL) async throws -> Double {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw MeetingRecorderError.message("恢复目标已存在，未覆盖文件。") }
        guard candidate.directory.resolvingSymlinksInPath().path == candidate.directory.path else { throw MeetingRecorderError.message("恢复目录已变化，请重新检查。") }
        if let mix = candidate.existingMix {
            guard mix.resolvingSymlinksInPath().path == candidate.directory.appendingPathComponent("meeting.m4a").path else { throw MeetingRecorderError.message("混音路径已变化，请重新检查。") }
        }
        for track in candidate.tracks {
            let expected = candidate.directory.appendingPathComponent(track.kind == .microphone ? "microphone.caf" : "system.caf")
            guard track.url.resolvingSymlinksInPath().path == expected.path else { throw MeetingRecorderError.message("原轨路径已变化，请重新检查。") }
        }
        let temporary = candidate.directory.appendingPathComponent("recovery-\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: temporary) }
        let source: URL
        if let mix = candidate.existingMix { source = mix }
        else { try await MeetingAudioMixer.mix(tracks: candidate.tracks, destination: temporary, duration: candidate.duration); source = temporary }
        try Task.checkCancellation()
        guard !fm.fileExists(atPath: destination.path) else { throw MeetingRecorderError.message("恢复目标已存在，未覆盖文件。") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".recovery-\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        let duration = try audioDuration(staging)
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
        return duration
    }
}
