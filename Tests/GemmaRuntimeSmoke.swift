import Foundation
final class GemmaTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ value:String) { lock.lock(); text += value; lock.unlock() }
    var result:String { lock.lock(); defer { lock.unlock() }; return text }
}
@main struct GemmaRuntimeSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        let suite = "cohear-gemma-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("gemma-3-4b-it-q4", forKey:"optionalGemma.activeModel.v1")
        let runtime = GemmaRuntime(modelDirectory:URL(fileURLWithPath:args[2]), defaults:defaults, executable:URL(fileURLWithPath:args[1]))
        let tokens = GemmaTokens()
        let start = Date()
        do {
            let result = try await runtime.generate(system:"用中文根据给定资料回答，不能编造。", prompt:"会议转录：[T001]我们决定周五前完成桌面录音和实时中文转写，由小王负责。请用两句话总结决定与负责人，并引用[T001]。") { tokens.append($0) }
            precondition(!result.isEmpty && !tokens.result.isEmpty && result.contains("[T001]"))
            precondition(result.contains("周五") && result.contains("小王"))
            print("PASS: 真实Gemma4B离线中文生成、流式token、真实来源引用；用时\(Int(Date().timeIntervalSince(start)))秒。\n\(result)")
            let second = try await runtime.generate(system:"根据资料简短回答。",prompt:"[T001]负责人是小王。谁负责？引用编号。",onToken:{_ in})
            precondition(second.contains("小王"))
            print("PASS: 同进程后续推理成功。")
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
}
