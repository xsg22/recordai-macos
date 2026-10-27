import Foundation
@main struct AccountRestoreSmoke {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let suite = "cohear-account-smoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = DingTalkAccountConnection(defaults: defaults, executable: URL(fileURLWithPath: args[1]))
        await account.restore()
        guard account.connected, !account.selectedProfile.isEmpty else { throw MCPError.message("已有钉钉身份恢复失败") }
        account.disconnect()
        await account.restore()
        precondition(!account.connected, "解除关联后不能自动重新连接")
        let response = try AccountCommandRunner.parse(Data("正在执行\n{\"ok\":true,\"data\":{}}".utf8))
        precondition(response["ok"] as? Bool == true)
        do { _ = try AccountCommandRunner.parse(Data("{\"ok\":false}".utf8)); fatalError("失败不能成功") } catch is MCPError { }
        print("PASS: 钉钉已有身份只读恢复、明确profile、解除关联、CLI JSON失败识别。未发送数据。")
    }
}
