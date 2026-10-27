import Foundation
@main struct GemmaCancellationSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        let suite = "cohear-gemma-cancel-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("gemma-3-4b-it-q4", forKey:"optionalGemma.activeModel.v1")
        let runtime = GemmaRuntime(modelDirectory:URL(fileURLWithPath:args[2]),defaults:defaults,executable:URL(fileURLWithPath:args[1]))
        let task = Task { try await runtime.generate(system:"用中文回答。",prompt:"详细解释如何做会议笔记。",onToken:{_ in}) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel(); await runtime.cancel()
        do { _ = try await task.value; fatalError("必须取消生成") } catch is CancellationError { }
        let result = try await runtime.generate(system:"只用一句中文回答。",prompt:"一加一等于几？",onToken:{_ in})
        precondition(result.contains("2") || result.contains("二"))
        await runtime.shutdown()
        print("PASS: Gemma加载阶段取消、任务收口、重新生成、模型进程释放。")
    }
}
