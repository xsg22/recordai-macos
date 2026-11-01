import SwiftUI

struct AgentConnectionView: View {
    @ObservedObject var state: AppState
    var onboarding = false
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Label(onboarding ? "让你的 AI 助手使用这段录音" : "连接你的 AI 助手", systemImage: "sparkles")
                    .font(AppTypography.heading)
                Spacer()
                if onboarding { Button("稍后") { state.dismissAgentOnboarding() } }
            }
            Text("复制提示词，发给 Codex、Claude Code、WorkBuddy、豆包等助手。由助手安装 RecordAI Skill，并验证转录查询。")
                .font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(copied ? "再次复制接入提示词" : "复制接入提示词") { copied = state.copyAgentPrompt() }
                    .buttonStyle(RecordAIPrimaryButtonStyle())
                if copied { Label("已复制，粘贴到你使用的 AI 助手中", systemImage: "checkmark.circle").font(AppTypography.secondary).foregroundStyle(.green) }
            }
            if let issue = state.agentSetupIssue { Text(issue).font(AppTypography.secondary).foregroundStyle(.orange) }
            if !onboarding {
                Text("需要助手支持本机文件或命令访问。接入时不会自动录音；使用外部助手查询时，相关文字会交给该助手处理。")
                    .font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.onAppear { if onboarding { state.agentOnboardingDidAppear() } }
    }
}
