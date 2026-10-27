import Foundation

/// 只适配明确契约；不能把机器人群发或任意含send的工具当作个人同步。
struct PersonalSyncAction: Identifiable {
    let id: String
    let title: String
    let tool: String
    let bodyField: String
    let recipientField: String?
    let titleField: String

    static func discover(_ tools: [MCPTool]) -> [PersonalSyncAction] {
        tools.compactMap { tool in
            let personalMail = ["send_email", "gmail_send_email", "create_draft", "gmail_create_draft"].contains(tool.name)
            let personalDocument = ["create_document", "create_note"].contains(tool.name)
            guard personalMail || personalDocument,
                  let properties = tool.inputSchema["properties"] as? [String: [String: Any]] else { return nil }
            let title = personalMail ? "subject" : "title"
            let body = personalMail ? "body" : "content"
            let expected = Set([title, body] + (personalMail ? ["to"] : []))
            let required = Set(tool.inputSchema["required"] as? [String] ?? [])
            guard required.isSubset(of: expected),
                  properties[title]?["type"] as? String == "string",
                  properties[body]?["type"] as? String == "string",
                  !personalMail || properties["to"]?["type"] as? String == "string" else { return nil }
            return PersonalSyncAction(id: tool.name,
                title: personalMail ? (tool.name.contains("draft") ? "保存邮件草稿" : "发送到我的邮箱") : "保存为文档",
                tool: tool.name, bodyField: body, recipientField: personalMail ? "to" : nil, titleField: title)
        }
    }

    func template(recipient: String) throws -> String {
        var arguments = [titleField: "{{title}}", bodyField: "{{text}}"]
        if let recipientField {
            let value = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.contains("@"), !value.contains("\n"), !value.contains(","), !value.contains(";") else {
                throw MCPError.message("请输入一个你自己的邮箱地址。")
            }
            arguments[recipientField] = value
        }
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
