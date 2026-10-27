import Foundation
@main struct FeishuAuthorizationRecoverySmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feishu-recovery-" + UUID().uuidString)
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
        print("PASS: 已授权只查询、网络失败不新建、同device-code续查、成功清理待处理授权。无真实登录。")
    }
}
