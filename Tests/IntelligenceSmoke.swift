import Foundation

@main struct IntelligenceSmoke {
    static func main() async throws {
        let simple = MeetingIntelligenceInput(title: "产品会议", transcript: "负责人小王确认明天验证中文转录。", notes: "需要离线模式")
        let prompt = try MeetingIntelligencePrompt.make(operation: .summary, input: simple)
        precondition(prompt.sources.map(\.id) == ["T001", "N001"])
        precondition(!prompt.contextWasTruncated)
        precondition(prompt.system.contains("禁止编造") && prompt.system.contains("不是时间戳"))
        precondition(prompt.prompt.contains("负责人或期限未说明"))
        let long = MeetingIntelligenceInput(title: "长会议", transcript: String(repeating: "历史讨论。", count: 6000) + "最后提出问题：上线风险是什么？", notes: "手写纪要原稿")
        let live = try MeetingIntelligencePrompt.make(operation: .liveQuestions, input: long)
        precondition(live.contextWasTruncated)
        precondition(live.sources.contains { $0.text.contains("上线风险") })
        precondition(live.sources.reduce(0) { $0 + $1.text.count + $1.id.count + 20 } <= MeetingIntelligencePrompt.sourceBudget)
        precondition(live.prompt.contains("仅有界选取") && live.prompt.contains("最新转录编号"))
        let answer = try MeetingIntelligencePrompt.make(operation: .answer, input: long, question: "上线风险是什么？")
        precondition(answer.sources.contains { $0.text.contains("上线风险") })
        let bounded = try MeetingIntelligencePrompt.make(operation: .answer, input: long,
            question: String(repeating: "中文问题", count: 3000))
        precondition(bounded.system.count + bounded.prompt.count <= 4500)
        // 测试生成回调只回传mock标记；不是向用户展示的AI结果。
        let model = MeetingIntelligence { system, prompt, onToken in
            precondition(system.contains("离线会议助手"))
            precondition(prompt.contains("<meeting_sources>"))
            onToken("mock-token")
            return "mock-result [T001] [N001] [T999]"
        }
        let result = try await model.enhanceNotes(simple)
        precondition(result.originalNotes == simple.notes)
        precondition(result.citedSources.map(\.id) == ["T001", "N001"])
        precondition(result.unsupportedCitationIDs == ["T999"])
        do {
            _ = try await model.answer(question: " ", input: simple)
            fatalError("应拒绝空问题")
        } catch MeetingIntelligenceError.emptyQuestion { }
        do {
            _ = try await model.summarize(MeetingIntelligenceInput(title: "空会议", transcript: " ", notes: ""))
            fatalError("不能在无资料时生成")
        } catch MeetingIntelligenceError.noMaterial { }
        let empty = MeetingIntelligence { _, _, _ in "  " }
        do {
            _ = try await empty.summarize(simple)
            fatalError("应拒绝空生成")
        } catch MeetingIntelligenceError.emptyResponse { }
        let calls = IntelligenceCalls()
        let tokenLog = IntelligenceTokens()
        let reducer = MeetingIntelligence { _, prompt, onToken in
            await calls.append(prompt)
            let regex = try NSRegularExpression(pattern: "\\[([TN][0-9]{3,})\\]")
            let citations = regex.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)).compactMap {
                Range($0.range, in: prompt).map { String(prompt[$0]) }
            }
            let unique = Array(Set(citations)).sorted().joined(separator: " ")
            let final = prompt.contains("综合为整场会议摘要")
            onToken(final ? "final-token" : "intermediate-token")
            return final ? "分段汇总 \(unique)" : String(repeating: "测试压缩摘要", count: 80) + " " + unique
        }
        let complete = try await reducer.summarize(long, onToken: { tokenLog.append($0) })
        let originalSources = MeetingIntelligencePrompt.allSources(long)
        let prompts = await calls.values()
        let mapPrompts = prompts.filter { $0.contains("] 转录") || $0.contains("] 手工笔记") }
        for source in originalSources {
            precondition(mapPrompts.contains { $0.contains("[\(source.id)]") && $0.contains(source.text) })
        }
        precondition(complete.sources == originalSources && !complete.contextWasTruncated)
        precondition(complete.unsupportedCitationIDs.isEmpty)
        precondition(tokenLog.values() == [complete.text])
        precondition(prompts.contains { $0.contains("---分段汇总---") && !$0.contains("综合为整场会议摘要") })
        precondition(prompts.allSatisfy { $0.count < 4500 })
        let failedCalls = IntelligenceCalls()
        let failure = MeetingIntelligence { _, prompt, onToken in
            await failedCalls.append(prompt)
            if await failedCalls.values().count == 2 { throw MeetingIntelligenceError.emptyResponse }
            return "测试 [T001]"
        }
        do {
            _ = try await failure.summarize(long)
            fatalError("中间失败不能返回完整结果")
        } catch MeetingIntelligenceError.emptyResponse { }
        let repairCalls = IntelligenceCalls()
        let repairTokens = IntelligenceTokens()
        let repairModel = MeetingIntelligence { system, prompt, onToken in
            await repairCalls.append(system + "\n" + prompt)
            onToken("不得流入界面的草稿")
            guard prompt.contains("<invalid_draft>") else { return "错误稿 [T999999]" }
            precondition(prompt.contains("非法来源编号：T999999"))
            precondition(system.count + prompt.count <= 7000)
            let marker = "本次唯一合法来源编号："
            let allowed = system.components(separatedBy: marker).last!
            let first = allowed.components(separatedBy: ", ").first!
            return "已修正有依据摘要 " + first
        }
        let repaired = try await repairModel.summarize(long, onToken: { repairTokens.append($0) })
        precondition(repaired.unsupportedCitationIDs.isEmpty && !repaired.contextWasTruncated)
        precondition(repairTokens.values() == [repaired.text])
        let retries = await repairCalls.values()
        precondition(retries.contains { $0.contains("<invalid_draft>") })
        precondition(!retries.contains { $0.contains("每项事实必须保留原始来源引用 [T001]") })
        let fabricated = MeetingIntelligence { _, _, _ in "虚构引用 [T999999]" }
        do {
            _ = try await fabricated.summarize(long)
            fatalError("不能接受不在map中的引用")
        } catch MeetingIntelligenceError.invalidCitation { }
        let cancelled = MeetingIntelligence { _, _, _ in throw CancellationError() }
        do {
            _ = try await cancelled.summarize(long)
            fatalError("取消不能返回完整摘要")
        } catch is CancellationError { }
        let tooLarge = MeetingIntelligenceInput(title: "超长", transcript: String(repeating: "字", count: 100001), notes: "")
        do {
            _ = try await reducer.summarize(tooLarge)
            fatalError("必须拒绝过大资料")
        } catch MeetingIntelligenceError.materialTooLarge { }
        print("MeetingIntelligence smoke passed（mock仅用于契约测试，无模型/网络调用）")
    }
}

private actor IntelligenceCalls {
    private var prompts: [String] = []
    func append(_ value: String) { prompts.append(value) }
    func values() -> [String] { prompts }
}
private final class IntelligenceTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []
    func append(_ value: String) { lock.lock(); tokens.append(value); lock.unlock() }
    func values() -> [String] { lock.lock(); defer { lock.unlock() }; return tokens }
}
