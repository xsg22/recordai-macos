import Foundation

@main struct LocalizationSmoke {
    @MainActor static func main() throws {
        let language = AppLanguage.shared
        let previous = language.selection
        defer { language.selection = previous }
        language.selection = .english
        precondition(L10n.text("开始新录音") != "开始新录音", "Bundle catalog must be loaded")
        precondition(RecordingSessionMode.conference.title == "Full recording")
        precondition(MeetingRecordingMode.meeting.title == "Microphone + system audio")
        precondition(L10n.text("录音 ") == "Recording ")
        precondition(RecordingSessionMode.conference.rawValue == "conference", "Display terminology must not rename persisted session modes")
        precondition(L10n.processingStatus("正在区分发言人 · 第 1/2 段录音 · 正文已保存") == "Identifying speakers · Audio part 1/2 · Transcript saved")
        precondition(L10n.text("录音原轨已保存至 完成{1}，合成失败：保存{0}") == "Original tracks saved to 完成{1}. Mixing failed: 保存{0}")
        precondition(L10n.format("{0} 个录音", "完成{1}").contains("完成{1}"))
        let suite = "TalkTuck-language-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppLanguage(defaults: defaults, initial: .system)
        preferences.selection = .english
        precondition(defaults.string(forKey: AppLanguage.preferenceKey) == "en")
        precondition(preferences.effective == .english && preferences.locale.identifier == "en")
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("TalkTuck-language-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var record = MeetingRecord(title: "完成{1}", text: "保存。\nHello, TalkTuck.", status: .completed)
        record.transcriptParagraphs = [TranscriptParagraph(text: "保存。", start: 1, end: 2, speakerIDs: ["0"]),
                                       TranscriptParagraph(text: "Hello, TalkTuck.", separator: "\n", start: 3, end: 5, speakerIDs: ["1"])]
        record.speakerNames = ["0": "发言人 1", "1": "完成"]
        record.customSpeakerNameIDs = ["1"]
        _ = try library.save(record)
        let canonical = try AgentCodec.encoder().encode(AgentDataPublisher.snapshot(record, libraryRoot: root))
        let canonicalMarkdown = AgentDataPublisher.markdown(record)
        precondition(record.displaySpeakerName("0") == "Speaker 1")
        precondition(record.displaySpeakerName("1") == "完成")
        let english = AgentDataPublisher.presentationMarkdown(record)
        precondition(english.contains("## Transcript") && english.contains("# 完成{1}") && english.contains("保存。"))
        language.selection = .simplifiedChinese
        precondition(L10n.text("开始新录音") == "开始新录音")
        precondition(RecordingSessionMode.conference.title == "整段录音")
        precondition(MeetingRecordingMode.meeting.title == "麦克风 + 系统声音")
        precondition(record.displaySpeakerName("0") == "发言人 1")
        let afterSwitch = try AgentCodec.encoder().encode(AgentDataPublisher.snapshot(record, libraryRoot: root))
        precondition(afterSwitch == canonical)
        precondition(AgentDataPublisher.markdown(record) == canonicalMarkdown)
        let state = AppState(storageURL: root, connectionNamespace: suite)
        state.select(record.id)
        let oldTranscription = state.language
        defer { state.language = oldTranscription }
        state.language = "en"
        language.selection = .english
        precondition(state.language == "en" && state.current?.language == record.language)
        precondition(state.renameSpeaker("0", name: "发言人 3"))
        let reloaded = try library.load(record.id)
        precondition(reloaded.displaySpeakerName("0") == "发言人 3", "Custom names stay verbatim after restart")
        let setup = AgentSetup(appURL: Bundle.main.bundleURL, dataRoot: root.appendingPathComponent("AgentData"))
        precondition(setup.prompt(interfaceLanguage: "en").contains("setup --json"))
        print("PASS: UI catalog, preference persistence, independent transcription language, verbatim user data, speaker names, exports and stable Agent snapshot")
        if CommandLine.arguments.count == 6 {
            let args = CommandLine.arguments
            let engine = TranscriptionEngine(), audio = URL(fileURLWithPath: args[3])
            let started = Date()
            let result = try engine.transcribe(audio: audio, model: URL(fileURLWithPath: args[2]), executable: URL(fileURLWithPath: args[1]), language: args[4])
            precondition(!result.text.isEmpty && result.subtitles.contains("-->"))
            precondition(result.text.range(of: "[A-Za-z]{3}", options: .regularExpression) != nil)
            if args[4] == "auto" { precondition(result.text.range(of: "[\\p{Han}]", options: .regularExpression) != nil) }
            let rows = try engine.analyzeSpeakers(audio: audio, model: URL(fileURLWithPath: args[2]), executable: URL(fileURLWithPath: args[1]), transcript: result, language: args[4])
            precondition(rows.map { $0.separator + $0.text }.joined() == result.text)
            precondition(rows.allSatisfy { ($0.start ?? -1) >= 0 && ($0.end ?? -1) >= ($0.start ?? 0) })
            let out = URL(fileURLWithPath: args[5]); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try result.text.write(to: out.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            try result.subtitles.write(to: out.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
            try JSONEncoder().encode(rows).write(to: out.appendingPathComponent("paragraphs.json"))
            let report: [String: Any] = ["language": args[4], "processingSeconds": Date().timeIntervalSince(started), "paragraphs": rows.count, "textPreserved": true, "realModelInference": true]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("report.json"))
            print("PASS: real transcription + speaker alignment (\(args[4]))\n\(result.text)")
        }
    }
}
