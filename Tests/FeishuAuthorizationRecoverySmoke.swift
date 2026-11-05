import Foundation
@main struct FeishuAuthorizationRecoverySmoke {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("feishu-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture")
        let calls = root.appendingPathComponent("calls")
        let pendingKey = "feishu-recovery-test-" + UUID().uuidString
        defer { try? MCPKeychain.delete(account: pendingKey) }
        let success = #"{"appId":"test-app","identities":{"user":{"available":true,"openId":"self","userName":"测试用户"}}}"#
        func writeFixture(_ body: String) throws {
            let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + calls.path + "'\n" + body
            try script.write(to: fixture, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        }
        try writeFixture("printf '%s\\n' '" + success + "'\n")
        let account = FeishuAccountConnection(executable: fixture, pendingAccount: pendingKey)
        await account.connect()
        precondition(account.connected)
        let first = try String(contentsOf: calls, encoding: .utf8)
        precondition(!first.contains("auth login"), "已有授权不能新申请")
        await account.checkAuthorization()
        precondition(account.connected)

        try writeFixture("printf '%s\\n' '{\"ok\":false,\"error\":{\"type\":\"network\"}}'\nexit 1\n")
        let unavailable = FeishuAccountConnection(executable: fixture, pendingAccount: pendingKey)
        await unavailable.connect()
        let failed = try String(contentsOf: calls, encoding: .utf8)
        precondition(!failed.contains("config init") && !failed.contains("auth login"), "查询失败不能创建应用或新授权")

        try MCPKeychain.save(MCPCredential(accessToken: "existing-test-device-code", expiresAt: Date().addingTimeInterval(600)), account: pendingKey)
        let marker = root.appendingPathComponent("authorized").path
        try writeFixture("""
if [ "$4" = "status" ]; then
  if [ -f '\(marker)' ]; then
    printf '%s\\n' '\(success)'
  else
    printf '%s\\n' '{"appId":"test-app","identities":{"user":{"available":false}}}'
  fi
elif [ "$4" = "login" ] && [ "$5" = "--device-code" ] && [ "$6" = "existing-test-device-code" ]; then
  touch '\(marker)'
  printf '%s\\n' '{"ok":true}'
else
  exit 2
fi
""")
        let resumed = FeishuAccountConnection(executable: fixture, pendingAccount: pendingKey)
        await resumed.connect()
        precondition(resumed.connected)
        let all = try String(contentsOf: calls, encoding: .utf8)
        precondition(all.contains("--device-code existing-test-device-code"))
        precondition(!all.contains("--no-wait"), "必须续旧申请而不是申请新code")
        let remaining = try MCPKeychain.read(account: pendingKey)
        precondition(remaining == nil)

        try Data().write(to: calls)
        try writeFixture("printf '%s\\n' '{\"appId\":\"test-app\",\"identities\":{\"user\":{\"available\":false}}}'\n")
        let restoredPending = FeishuAccountConnection(executable: fixture, pendingAccount: pendingKey,
            pendingCredentialReader: { MCPCredential(accessToken: "isolated-pending-code", expiresAt: Date().addingTimeInterval(600)) })
        await restoredPending.checkAuthorization()
        precondition(restoredPending.hasPendingAuthorization && !restoredPending.pendingAuthorizationExpired)
        precondition(restoredPending.status.contains("已有授权申请"))
        let afterRestore = try String(contentsOf: calls, encoding: .utf8)
        precondition(!afterRestore.contains("auth login") && !afterRestore.contains("config init"), "恢复页面标记只能读取，不能自动续查或新建")

        let expired = FeishuAccountConnection(executable: fixture, pendingAccount: pendingKey,
            pendingCredentialReader: { MCPCredential(accessToken: "isolated-expired-code", expiresAt: Date.distantPast) })
        await expired.checkAuthorization()
        precondition(expired.hasPendingAuthorization && expired.pendingAuthorizationExpired, "过期申请也应保留显式重新申请入口")
        await expired.connect()
        precondition(expired.error?.contains("过期") == true && expired.hasPendingAuthorization)
        let afterExpired = try String(contentsOf: calls, encoding: .utf8)
        precondition(!afterExpired.contains("auth login") && !afterExpired.contains("config init"), "过期不能隐式启动新授权")

        try writeFixture("printf '%s\\n' '{\"ok\":false,\"error\":{\"type\":\"config\",\"subtype\":\"not_configured\"}}'\nexit 1\n")
        await restoredPending.connect()
        precondition(restoredPending.hasPendingAuthorization && restoredPending.error != nil)
        let afterMissingProfile = try String(contentsOf: calls, encoding: .utf8)
        precondition(!afterMissingProfile.contains("config init") && !afterMissingProfile.contains("auth login"), "已有申请但配置缺失时不能隐式重复初始化")
        print("PASS: 已授权只查询、网络失败不新建、同device-code续查、成功清理、页面恢复待处理标记、过期显式重试、配置缺失不重复初始化。无真实登录。")
    }
}
