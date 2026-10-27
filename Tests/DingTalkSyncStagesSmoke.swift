import Foundation
@main struct DingTalkSyncStagesSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohear-sync-stages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture")
        let script = #"""
#!/bin/sh
printf '%s\n' "$1 $2" >> calls
case "$1 $2" in
"profile list") printf '%s\n' '{"success":true,"profiles":[{"profile":"corp:self","userName":"测试自己","corpName":"测试组织","status":"active","isCurrent":true}]}' ;;
"auth status") printf '%s\n' '{"success":true,"authenticated":true,"token_valid":true,"corp_id":"corp","user_id":"self"}' ;;
"doc +create") cat >/dev/null; printf '%s\n' '{"ok":true,"data":{"nodeId":"doc-test"}}' ;;
"doc +fetch") exit 1 ;;
"drive info") printf '%s\n' '{"success":true,"url":"https://alidocs.dingtalk.com/i/nodes/doc-test"}' ;;
"chat +messages-send") printf '%s\n' '{"success":true,"result":{"openTaskId":"task-test"}}' ;;
*) exit 1 ;;
esac
"""#
        // helper工作目录固定到fixture目录，mock服务不接触网络。
        let wrapped = script.replacingOccurrences(of: "printf '%s\\n' \"$1 $2\" >> calls", with: "printf '%s\\n' \"$1 $2\" >> '" + root.appendingPathComponent("calls").path + "'")
        try wrapped.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let suite = "cohear-stages-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = DingTalkAccountConnection(defaults: defaults, executable: fixture)
        await account.restore()
        precondition(account.connected)
        let receipt = try await account.sync(title: "会议", text: "本次转录正文")
        precondition(receipt.warning != nil, "回读失败应是单独警告")
        precondition(receipt.remoteURL != nil)
        precondition(receipt.notificationStatus?.contains("等待投递") == true)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        precondition(calls.components(separatedBy: "doc +create").count == 2, "只创建一次文档")
        precondition(calls.components(separatedBy: "chat +messages-send").count == 2, "只提交一次提醒")
        print("PASS: 文档已创建+回读失败仍保留成功/真实返回链接/本人提醒独立提交/不重复创建。仅本地假服务。")
    }
}
