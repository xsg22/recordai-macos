import Foundation
@main struct PersonalActionSmoke {
    static func main() throws {
        let mail = MCPTool(name: "send_email", description: "", inputSchema: ["properties": ["subject": ["type": "string"], "body": ["type": "string"], "to": ["type": "string"]], "required": ["subject", "body", "to"]])
        let robot = MCPTool(name: "batch_send_robot_msg_to_users", description: "", inputSchema: mail.inputSchema)
        precondition(PersonalSyncAction.discover([robot]).isEmpty)
        let action = PersonalSyncAction.discover([mail]).first!
        let args = try MCPClient.arguments(template: action.template(recipient: "me@example.com"), title: "会议", text: "正文")
        precondition(args["to"] as? String == "me@example.com")
        precondition(args["body"] as? String == "正文")
        let unknown = MCPTool(name: "send_email", description: "", inputSchema: ["properties": mail.inputSchema["properties"]!, "required": ["account_id"]])
        precondition(PersonalSyncAction.discover([unknown]).isEmpty)
        do { _ = try action.template(recipient: "a@example.com,b@example.com"); fatalError("必须拒绝多收件人") } catch is MCPError { }
        print("PASS: 个人业务适配、实际参数生成、机器人服务和未知必填字段不自动适配、多收件人拒绝。")
    }
}
