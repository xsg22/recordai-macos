import Foundation

enum DingTalkSyncResult {
    static func documentURL(_ value: Any) -> URL? {
        if let dictionary = value as? [String: Any] {
            for key in ["url", "webUrl", "docUrl", "documentUrl", "linkUrl", "link", "doc_url"] {
                if let string = dictionary[key] as? String, let url = URL(string: string), url.scheme == "https",
                   let host = url.host, host == "dingtalk.com" || host.hasSuffix(".dingtalk.com") { return url }
            }
            for key in dictionary.keys.sorted() {
                if let child = dictionary[key], let url = documentURL(child) { return url }
            }
        } else if let array = value as? [Any] {
            for item in array { if let url = documentURL(item) { return url } }
        }
        return nil
    }

    /// 只使用同一profile的auth真实返回值；正文只包含标题和可用链接，不包含会议全文。
    static func notificationArguments(auth: [String: Any], profile: String, title: String, url: URL?, idempotencyKey: String) throws -> [String] {
        guard auth["authenticated"] as? Bool == true,
              let corp = auth["corp_id"] as? String, let user = auth["user_id"] as? String,
              !user.isEmpty, corp + ":" + user == profile else {
            throw MCPError.message("钉钉身份不匹配，已停止消息提醒，文档不受影响。")
        }
        let safeTitle = String(title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(150))
        let text = "会议已同步到钉钉文档：" + safeTitle + "\n" + (url?.absoluteString ?? "可在钉钉“我的文档”中查看。")
        // --yes的边界是产品同步确认页里明确勾选的“通知我”，不额外发送给其他人或群。
        return ["chat", "+messages-send", "--as", "user", "--user", user, "--text", text,
                "--idempotency-key", idempotencyKey, "--profile", profile, "--timeout", "20", "--format", "json", "--yes"]
    }

    static func notificationDescription(_ result: [String: Any]) -> String {
        guard result["ok"] as? Bool != false, result["success"] as? Bool != false, result["error"] == nil else {
            return "钉钉提醒发送失败；文档已保存。"
        }
        // 发送API常返回异步任务。任务标识只能证明已提交，不能当作送达/已读证明。
        if find("openTaskId", in: result) != nil { return "钉钉提醒已提交，等待投递。" }
        if let state = find("deliveryStatus", in: result) as? String, state.lowercased() == "delivered" {
            return "已确认提醒送达钉钉“我”。"
        }
        return "钉钉提醒请求已返回，投递状态尚未确认。"
    }
    private static func find(_ key: String, in value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            if let direct = dictionary[key] { return direct }
            for child in dictionary.values { if let value = find(key, in: child) { return value } }
        } else if let array = value as? [Any] {
            for child in array { if let value = find(key, in: child) { return value } }
        }
        return nil
    }
}
