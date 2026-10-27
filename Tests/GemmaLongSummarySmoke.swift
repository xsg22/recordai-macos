import Foundation
@main struct GemmaLongSummarySmoke {
    static func main() async throws {
        let args=CommandLine.arguments
        let suite="cohear-gemma-long-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("gemma-3-4b-it-q4",forKey:"optionalGemma.activeModel.v1")
        let runtime=GemmaRuntime(modelDirectory:URL(fileURLWithPath:args[2]),defaults:defaults,executable:URL(fileURLWithPath:args[1]))
        let service=MeetingIntelligence { system,prompt,token in try await runtime.generate(system:system,prompt:prompt,onToken:token) }
        let background=String(repeating:"讨论背景：我们正在开发会议客户端，录音和实时转写应在本机进行。会议参与者确认这是技术背景，没有新增决定。\n",count:50)
        let transcript="项目甲由小王负责，本周五前完成桌面录音。\n"+background+"项目乙由小李负责，下周二前完成中文转写。\n"+background+"项目丙由小陈负责，下周三前完成笔记增强。"
        do {
            let result=try await service.summarize(MeetingIntelligenceInput(title:"三项目长会议测试",transcript:transcript,notes:""),onProgress:{text in print(text); fflush(stdout)})
            precondition(!result.contextWasTruncated && result.sources.count>6)
            precondition(result.unsupportedCitationIDs.isEmpty)
            precondition(result.text.contains("小王") && result.text.contains("小李") && result.text.contains("小陈"),"跨首中尾的决定不能遗漏")
            print("PASS: 真Gemma长转录全覆盖分块汇总，首中尾三个负责人保留，引用均有效。\n"+result.text)
            await runtime.shutdown()
        } catch { await runtime.shutdown(); throw error }
    }
}
