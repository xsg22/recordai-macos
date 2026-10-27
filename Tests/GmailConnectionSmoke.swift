import Foundation
@main struct GmailConnectionSmoke {
    static func check(_ value: Bool, _ message: String) throws { if !value { throw MCPError.message("FAIL: " + message) } }
    static func main() async throws {
        // Fixture follows public Pipedream component propDefinitions; live MCP naming still requires authorized verification.
        let profile = MCPTool(name: "gmail-get-current-user", description: "Returns the authenticated Gmail user's name, email address, and mailbox stats", inputSchema: ["type": "object", "properties": [:], "required": []], annotations: ["readOnlyHint": true])
        let send = MCPTool(name: "gmail-send-email", description: "Send a new email", inputSchema: ["type": "object", "properties": ["to": ["type": "array", "items": ["type": "string"]], "subject": ["type": "string"], "body": ["type": "string"], "bodyType": ["type": "string"]], "required": ["to", "subject", "body"]], annotations: ["readOnlyHint": false])
        let selected = try GmailAccountConnection.contract(tools: [profile, send])
        try check(selected.send.name == "gmail-send-email", "exact send contract")
        let account = try GmailAccountConnection.account(from: ["structuredContent": ["name": "Alice", "emailAddress": "alice@example.com"]])
        let template = try GmailAccountConnection.template(email: account.email)
        let args = try MCPClient.arguments(template: template, title: "中文会议", text: "最终正文")
        try check(args["to"] as? [String] == ["alice@example.com"] && args["bodyType"] as? String == "plaintext", "send only to verified self")
        try check(args["subject"] as? String == "中文会议" && args["body"] as? String == "最终正文", "automatic mapping")
        let textAccount = try GmailAccountConnection.account(from: ["content": [["type": "text", "text": "{\"emailAddress\":\"bob@example.com\"}"]]])
        try check(textAccount.email == "bob@example.com", "JSON content account")
        var rejected = false
        do { _ = try GmailAccountConnection.contract(tools: [MCPTool(name: "search_tools", description: "discover tools", inputSchema: [:])]) } catch { rejected = true }
        try check(rejected, "generic discovery is not guessed")
        rejected = false
        do { _ = try GmailAccountConnection.account(from: ["content": [["text": "Please connect Gmail: https://pipedream.com/connect"]]]) } catch { rejected = true }
        try check(rejected, "connect link is not an account")
        var wrong = send
        // A lookalike tool name is rejected even if its input fields resemble the send contract.
        wrong = MCPTool(name: "other-send-email", description: send.description, inputSchema: send.inputSchema)
        rejected = false
        do { _ = try GmailAccountConnection.contract(tools: [profile, wrong]) } catch { rejected = true }
        try check(rejected, "no fuzzy tool matching")
        print("PASS: Gmail source contract / verified self recipient / mapping / fail closed discovery and account")
    }
}
