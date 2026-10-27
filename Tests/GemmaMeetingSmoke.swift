import Foundation
@main struct GemmaMeetingSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        let suite = "cohear-gemma-meeting-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("gemma-3-4b-it-q4", forKey:"optionalGemma.activeModel.v1")
        let runtime = GemmaRuntime(modelDirectory:URL(fileURLWithPath:args[2]),defaults:defaults,executable:URL(fileURLWithPath:args[1]))
        let service = MeetingIntelligence { system,prompt,token in try await runtime.generate(system:system,prompt:prompt,onToken:token) }
        let input = MeetingIntelligenceInput(title:"桌面会议功能讨论",transcript:"今天讨论桌面会议软件。小王问：什么时候完成实时中文转写？小李回答：我们决定本周五前完成，小王负责开发，小李验收。桌面录音必须支持麦克风和系统声音。下周一演示给团队。",notes:"周五 实时中文，小王开发，小李验收。周一演示。")
        do {
            let summary = try await service.summarize(input)
            precondition(summary.text.contains("小王") && summary.text.contains("周五"))
            precondition(!summary.citedSources.isEmpty)
            print("PASS: Gemma真实会议摘要与引用。\n" + summary.text); fflush(stdout)
            let enhanced = try await service.enhanceNotes(input)
            precondition(enhanced.originalNotes == input.notes && enhanced.text.contains("小王"))
            print("PASS: Gemma真实笔记增强，原稿保留。\n" + enhanced.text); fflush(stdout)
            let answer = try await service.answer(question:"谁负责开发，谁负责验收？",input:input)
            precondition(answer.text.contains("小王") && answer.text.contains("小李"))
            print("PASS: Gemma真实会议问答。\n" + answer.text); fflush(stdout)
            let live = try await service.liveQuestions(input)
            precondition(live.text.contains("周五") && !live.citedSources.isEmpty)
            print("PASS: Gemma真实Live Q&A，最近转录问题与回答。\n" + live.text); fflush(stdout)
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
}
