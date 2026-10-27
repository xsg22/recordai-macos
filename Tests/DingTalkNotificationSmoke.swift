import Foundation
@main struct DingTalkNotificationSmoke {
    static func main() throws {
        let auth: [String: Any] = ["authenticated": true, "corp_id": "corp-test", "user_id": "self-test"]
        let url = URL(string: "https://alidocs.dingtalk.com/i/nodes/real-result")!
        let args = try DingTalkSyncResult.notificationArguments(auth: auth, profile: "corp-test:self-test", title: "会议\n测试", url: url, idempotencyKey: "doc-test")
        precondition(args[args.firstIndex(of: "--user")! + 1] == "self-test")
        precondition(args[args.firstIndex(of: "--profile")! + 1] == "corp-test:self-test")
        precondition(args.contains("--idempotency-key") && !args.contains("--group") && !args.contains("--robot-code"))
        let text = args[args.firstIndex(of: "--text")! + 1]
        precondition(text.contains(url.absoluteString) && !text.contains("会议\n测试"))
        do { _ = try DingTalkSyncResult.notificationArguments(auth: auth, profile: "other:user", title: "", url: nil, idempotencyKey: "k"); fatalError("身份不匹配不能发送") } catch is MCPError { }
        precondition(DingTalkSyncResult.documentURL(["data": ["result": [["url":url.absoluteString]]]]) == url)
        precondition(DingTalkSyncResult.documentURL(["url":"https://dingtalk.com.evil.test/path"]) == nil)
        precondition(DingTalkSyncResult.notificationDescription(["data":["openTaskId":"task"]]).contains("等待投递"))
        precondition(!DingTalkSyncResult.notificationDescription(["success":true]).contains("送达"))
        precondition(DingTalkSyncResult.notificationDescription(["error":[:]]).contains("失败"))
        print("PASS: 同账号本人、标题/链接、幂等、无机器人/群发、身份错配拒绝、异步投递不冒充送达。未发真实消息。")
    }
}
