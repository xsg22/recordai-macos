import AVFoundation
import Foundation

@main struct CapturePolishSmoke {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func writeAudio(_ url: URL, amplitude: Float = 0.5, silentTail: Bool = false) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        for frame in 0..<32_000 {
            buffer.floatChannelData![0][frame] = 0
            buffer.floatChannelData![1][frame] = silentTail && frame >= 16_000 ? 0 : amplitude
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cohear-polish-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let audio = root.appendingPathComponent("wave.caf")
        try writeAudio(audio, silentTail: true)
        let store = AudioWaveformStore(directory: root.appendingPathComponent("WaveCache"))
        let wave = try await store.load(audio)
        check(abs(wave.duration - 2) < 0.001, "真实声波时长")
        check(wave.peaks.prefix(wave.peaks.count / 2).allSatisfy { abs($0 - 0.5) < 0.001 }, "双通道不能只读取静音左声道")
        check(wave.peaks.suffix(wave.peaks.count / 2).allSatisfy { $0 == 0 }, "静音不能显示伪造波形")
        let diskStore = AudioWaveformStore(directory: root.appendingPathComponent("WaveCache"))
        let cached = try await diskStore.load(audio)
        check(cached.identity == wave.identity && cached.peaks == wave.peaks, "缓存重新打开一致")
        try writeAudio(audio, amplitude: 0.2)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: audio.path)
        let changed = try await store.load(audio)
        check(changed.identity != wave.identity && changed.peaks.allSatisfy { abs($0 - 0.2) < 0.001 }, "同路径音频变化不能套用旧声波")
        check(!CaptureHealth.microphoneStalled(started: 0, lastFrame: nil, now: 7), "冷启动宽限")
        check(CaptureHealth.microphoneStalled(started: 0, lastFrame: nil, now: 9), "没有帧的断流可检测")
        check(!CaptureHealth.microphoneStalled(started: 0, lastFrame: 9.8, now: 10), "真正静音仍有帧，不能误报断连")

        let healthDirectory = root.appendingPathComponent("Health")
        try fm.createDirectory(at: healthDirectory, withIntermediateDirectories: true)
        let healthSink = MeetingAudioSink(directory: healthDirectory, started: 100) { _ in }
        let quietFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let quiet = AVAudioPCMBuffer(pcmFormat: quietFormat, frameCapacity: 160)!
        healthSink.appendMicrophone(quiet, at: 100)
        check(healthSink.lastFrame(for: .microphone) == nil, "空缓冲不算音频帧")
        quiet.frameLength = 160
        for i in 0..<160 { quiet.floatChannelData![0][i] = 0 }
        healthSink.appendMicrophone(quiet, at: 100)
        check(healthSink.lastFrame(for: .microphone) != nil, "真实静音帧应更新采集健康状态")
        _ = healthSink.finish()
        check(healthSink.level == 0, "静音电平真实为零")
        let aliasRoot = URL(fileURLWithPath: "/private/tmp/cohear-alias-" + UUID().uuidString)
        defer { try? fm.removeItem(at: aliasRoot) }
        let aliasLibrary = try MeetingLibrary(root: aliasRoot)
        let aliasRecord = MeetingRecord(title: "系统路径别名")
        _ = try aliasLibrary.save(aliasRecord)
        let aliasDestination = try aliasLibrary.recoveryDestination(for: aliasRecord.id)
        check(fm.fileExists(atPath: aliasDestination.deletingLastPathComponent().path), "不存在Audio目录时也应正确处理系统/private/tmp别名")
        let library = try MeetingLibrary(root: root.appendingPathComponent("Library"))
        var record = MeetingRecord(title: "恢复验收", text: "原文保留", notes: "手工笔记保留", status: .interrupted)
        _ = try library.save(record)
        let session = UUID()
        let directory = library.directory(for: record.id).appendingPathComponent("Capture/" + session.uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let mic = directory.appendingPathComponent("microphone.caf")
        try writeAudio(mic)
        let originalBytes = try Data(contentsOf: mic)
        let tracks = [MeetingAudioTrack(kind: .microphone, url: mic, offset: 0.5)]
        try JSONEncoder().encode(tracks).write(to: directory.appendingPathComponent("recording.json"))
        var scan = try CaptureRecovery.scan(meetingID: record.id, meetingDirectory: library.directory(for: record.id), managedAudio: [], importedSessions: [:])
        check(scan.candidates.count == 1 && abs(scan.candidates[0].duration - 2.5) < 0.01, "扫描保留原轨相对偏移")
        let destination = try library.recoveryDestination(for: record.id)
        let seconds = try await CaptureRecovery.prepare(scan.candidates[0], destination: destination)
        _ = try library.registerRecovery(destination, duration: seconds, session: session, warnings: ["测试：采集发生中断"], into: &record)
        check(record.audioFiles.count == 1 && record.pendingAudioFiles.count == 1 && record.status == .recorded, "恢复登记为待转录")
        check(record.captureWarnings == ["测试：采集发生中断"], "恢复质量提示应持久化")
        let publicRecording = try AgentReadStore(root: library.root.appendingPathComponent("AgentData")).read(record.id)
        check(publicRecording.captureWarnings == record.captureWarnings, "外部Agent可读到采集警告")
        record.recoveryMessage = nil
        _ = try library.save(record)
        check(try library.load(record.id).captureWarnings == ["测试：采集发生中断"], "清除任务提示不能清除采集警告")
        check(record.text == "原文保留" && record.notes == "手工笔记保留", "恢复不覆盖原文笔记")
        check(try Data(contentsOf: mic) == originalBytes, "原轨逐字节不变")
        let duplicate = try library.recoveryDestination(for: record.id)
        try fm.copyItem(at: destination, to: duplicate)
        let registered = try library.registerRecovery(duplicate, duration: seconds, session: session, into: &record)
        check(record.audioFiles.count == 1 && registered == destination && !fm.fileExists(atPath: duplicate.path), "重复恢复不重复追加")
        scan = try CaptureRecovery.scan(meetingID: record.id, meetingDirectory: library.directory(for: record.id), managedAudio: [destination], importedSessions: record.importedCaptureSessions)
        check(scan.candidates.isEmpty, "恢复后扫描幂等")
        let existing = root.appendingPathComponent("existing.m4a")
        try Data("用户已有文件".utf8).write(to: existing)
        do { _ = try await CaptureRecovery.prepare(CaptureRecoveryCandidate(id: session, meetingID: record.id, directory: directory, tracks: tracks, existingMix: destination, duration: seconds, warnings: []), destination: existing); preconditionFailure("不应覆盖") } catch { }
        check(try String(contentsOf: existing, encoding: .utf8) == "用户已有文件", "失败不能删除已有目标")

        // 旧版已导入的混音没有session标记，仍按完整内容去重。
        try fm.copyItem(at: destination, to: directory.appendingPathComponent("meeting.m4a"))
        scan = try CaptureRecovery.scan(meetingID: record.id, meetingDirectory: library.directory(for: record.id), managedAudio: [destination], importedSessions: [:])
        check(scan.candidates.isEmpty, "旧版副本按内容去重，不凭时长猜测")
        // 登记失败要回滚内存和新副本，同时保留原轨与已登记音频。
        let metadata = library.directory(for: record.id).appendingPathComponent("meeting.json")
        let backup = library.directory(for: record.id).appendingPathComponent("metadata.backup")
        try fm.moveItem(at: metadata, to: backup)
        try fm.createDirectory(at: metadata, withIntermediateDirectories: false)
        let rollbackAudio = try library.recoveryDestination(for: record.id)
        try fm.copyItem(at: destination, to: rollbackAudio)
        let originalRecord = record
        do { _ = try library.registerRecovery(rollbackAudio, duration: seconds, session: UUID(), into: &record); preconditionFailure("保存故障不应成功") } catch { }
        check(record == originalRecord && !fm.fileExists(atPath: rollbackAudio.path), "登记失败必须回滚")
        check(try Data(contentsOf: mic) == originalBytes, "失败时原轨仍完整")
        try fm.removeItem(at: metadata); try fm.moveItem(at: backup, to: metadata)
        var malicious = tracks; malicious[0] = MeetingAudioTrack(kind: .microphone, url: root.appendingPathComponent("private.caf"), offset: 0)
        try JSONEncoder().encode(malicious).write(to: directory.appendingPathComponent("recording.json"))
        scan = try CaptureRecovery.scan(meetingID: record.id, meetingDirectory: library.directory(for: record.id), managedAudio: [], importedSessions: [:])
        check(scan.candidates.isEmpty && !scan.warnings.isEmpty, "路径逃逸必须拒绝")

        // 使用真实AppState完成检查、恢复及登记，所有数据仍在临时库。
        try JSONEncoder().encode(tracks).write(to: directory.appendingPathComponent("recording.json"))
        let second = MeetingRecord(title: "恢复状态流", text: "保留旧文字", status: .interrupted)
        _ = try library.save(second)
        let secondDir = library.directory(for: second.id).appendingPathComponent("Capture/" + UUID().uuidString)
        try fm.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let secondMic = secondDir.appendingPathComponent("microphone.caf")
        try writeAudio(secondMic)
        try JSONEncoder().encode([MeetingAudioTrack(kind: .microphone, url: secondMic, offset: 0)]).write(to: secondDir.appendingPathComponent("recording.json"))
        let state = AppState(storageURL: library.root, connectionNamespace: "polish-")
        state.select(second.id); state.findRecoverableAudio(); state.cancelRecovery()
        for _ in 0..<300 where state.recoveryBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        check(!state.recoveryBusy && state.recoveryCandidates.isEmpty, "取消检查不会后台偷偷登记音频")
        state.findRecoverableAudio()
        for _ in 0..<300 where state.recoveryBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        check(!state.recoveryBusy && state.recoveryCandidates.count == 1, "真实状态扫描完成")
        state.recoverCapture(state.recoveryCandidates[0])
        for _ in 0..<500 where state.recoveryBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        check(!state.recoveryBusy && state.current?.pendingAudioFiles.count == 1 && state.text == "保留旧文字", "真实状态恢复并保存")
        state.seek(0.75)
        check(state.playbackTime == 0.75 && !state.playing, "波形可在播放前定位，不依赖峰值生成")
        check(QuitActivity.resolve(recording: false, preparing: false, transcribing: false, recovering: true, externalTask: false) == .recovering, "恢复未完成不强退")
        print("PASS: 真实双轨峰值/静音/缓存失效、无帧检测、原轨恢复/偏移/重复去重/路径拒绝/不覆盖、AppState恢复与播放前定位。无硬件采集或声音播放。")
    }
}
