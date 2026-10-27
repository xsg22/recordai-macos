import Foundation
@main struct NotionConnectionSmoke {
    @MainActor static func main() throws {
        let identity = MCPTool(name: "notion-get-self", description: "Current connection", inputSchema: ["type":"object", "properties":[:]], annotations: ["readOnlyHint":true])
        let create = MCPTool(name: "notion-create-pages", description: "Creates pages; without parent creates private page", inputSchema: ["type":"object", "properties":["pages":["type":"array"], "creation_mode":["type":"string", "enum":["draft"]], "allow_async":["type":"boolean"]], "required":["pages"]])
        let contract = try NotionAccountConnection.contract([identity, create])
        let template = try NotionAccountConnection.template(contract.create)
        let arguments = try MCPClient.arguments(template: template, title: "中文会议\"标题", text: "第一行\n第二行 {{title}}")
        let pages = arguments["pages"] as! [[String:Any]]
        precondition(pages.count == 1 && arguments["parent"] == nil && pages[0]["parent"] == nil)
        precondition((pages[0]["properties"] as? [String:String])?["title"] == "中文会议\"标题")
        precondition(pages[0]["content"] as? String == "第一行\n第二行 {{title}}")
        precondition(arguments["creation_mode"] as? String == "draft" && arguments["allow_async"] as? Bool == false)
        let user = try NotionAccountConnection.identity(["content":[["type":"text", "text":"{\"workspace\":{\"id\":\"workspace-test\",\"name\":\"个人工作区\"},\"user\":{\"type\":\"person\",\"name\":\"测试用户\"}}"]]])
        precondition(user.id == "workspace-test" && user.display.contains("个人工作区"))
        do { _ = try NotionAccountConnection.identity(["structuredContent":["workspace":["id":"w"],"user":["type":"bot"]]]); fatalError("机器人不能冒充个人连接") } catch is MCPError { }
        let pageURL = URL(string:"https://www.notion.so/meeting-page-test")!
        precondition(NotionAccountConnection.pageURL(["pages":[["url":pageURL.absoluteString]]]) == pageURL)
        precondition(NotionAccountConnection.pageURLFromText("{\"pages\":[{\"url\":\"https://www.notion.so/meeting-page-test\"}]}") == pageURL)
        precondition(NotionAccountConnection.pageURL(["url":"https://notion.so.evil.test/page"]) == nil)
        let unsupported = MCPTool(name: "notion-create-pages", description: "", inputSchema: ["properties":["pages":["type":"array"]], "required":["pages","parent"]])
        do { _ = try NotionAccountConnection.contract([identity, unsupported]); fatalError("不能忽略必填parent") } catch is MCPError { }
        let suite = "notion-smoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = MCPConnectionStore(defaults:defaults, namespace:suite)
        _ = NotionAccountConnection(store:store, defaults:defaults, metadataNamespace:suite)
        precondition(store.configuration.endpoint == "https://mcp.notion.com/mcp" && store.configuration.scope == "default")
        print("PASS: Notion官方固定端点/只读个人工作区/私人页面参数/正文安全替换/建页结果链接/未知必填项拒绝。未授权或建真实页面。")
    }
}
