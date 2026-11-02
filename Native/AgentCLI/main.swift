import Foundation

func jsonValue<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: AgentCodec.encoder().encode(value), options: [.fragmentsAllowed]) }
func output(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
}
func summaries(_ store: AgentReadStore, query: String = "", groupID: UUID? = nil, ungrouped: Bool = false) throws -> [[String: Any]] {
    try store.list().filter { $0.matches(query: query, groupID: groupID, ungrouped: ungrouped) }.map { record in
        var row: [String: Any] = ["id": record.id.uuidString, "title": record.title, "status": record.status, "revision": record.revision,
            "transcriptionReady": record.transcriptionReady, "ready": record.ready, "speakerAnalysisStatus": record.speakerAnalysisStatus]
        if let organization = record.organization { row["organization"] = try jsonValue(organization) }
        return row
    }
}
func uuid(_ value: String?) throws -> UUID {
    guard let value, let id = UUID(uuidString: value) else { throw CLIError.message("需要有效的录音UUID。") }; return id
}
enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
let defaultAgentRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CoHearTranscribe/AgentData")
let ownApplicationURL = AgentSetup.applicationURL(executable: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())
func setup(_ root: URL) -> AgentSetup { AgentSetup(appURL: ownApplicationURL, dataRoot: root) }
func runtime(_ root: URL) throws -> Any {
    do { return try jsonValue(RecordAIRuntimeStatus.read(root: root)) }
    catch { return ["available": false, "reason": "App 未运行、状态尚未就绪或状态文件不可读取。"] as [String: Any] }
}
func launchIfRequested(_ launch: Bool, action: String, root: URL) throws {
    guard launch else { return }
    guard action == "start_recording", root.standardizedFileURL.resolvingSymlinksInPath() == defaultAgentRoot.standardizedFileURL.resolvingSymlinksInPath(),
          ownApplicationURL.pathExtension == "app",
          NSDictionary(contentsOf: ownApplicationURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String == "com.byering.recordai" else {
        throw CLIError.message("仅支持启动当前安装包和默认资料目录的录音；自定义目录不会唤起其他 App。")
    }
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/open"); task.arguments = [ownApplicationURL.path]
    // Keep stdio MCP's stdout exclusively for JSON-RPC.
    task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
    try task.run(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw CLIError.message("未能打开 RecordAI，请手动打开后重试。") }
}
let toolNames = ["get_agent_setup", "list_recordings", "get_recording", "get_transcript", "get_audio_files", "get_changes", "get_recording_status", "get_command_result", "control_recording"]
func mcp(_ store: AgentReadStore) {
    while let line = readLine() {
        var requestID: Any = NSNull()
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
                try output(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]]); continue
            }
            guard let id = request["id"] else { continue }; requestID = id
            let params = request["params"] as? [String: Any] ?? [:]
            let result: Any
            switch method {
            case "initialize":
                let supported = ["2024-11-05", "2025-03-26", "2025-06-18"]
                let requested = params["protocolVersion"] as? String ?? ""
                result = ["protocolVersion": supported.contains(requested) ? requested : "2025-03-26", "capabilities": ["tools": [:], "resources": [:]], "serverInfo": ["name": "recordai", "version": setup(store.root).version]]
            case "ping": result = [:] as [String: String]
            case "tools/list":
                result = ["tools": toolNames.map { name -> [String: Any] in
                    let noArguments = ["get_agent_setup", "get_recording_status"].contains(name)
                    let properties: [String: Any] = name == "list_recordings" ? ["query": ["type": "string"], "groupId": ["type": "string", "format": "uuid"], "ungrouped": ["type": "boolean"]] : name == "get_changes" ? ["since": ["type": "integer", "minimum": 0]] : noArguments ? [:] : name == "get_command_result" ? ["commandId": ["type": "string", "format": "uuid"]] : name == "control_recording" ? ["action": ["type": "string", "enum": RecordAIControlQueue.actions], "launch": ["type": "boolean", "default": false]] : ["id": ["type": "string", "format": "uuid"], "includePreview": ["type": "boolean", "default": false]]
                    let required: [String] = name == "list_recordings" ? [] : name == "get_changes" ? ["since"] : noArguments ? [] : name == "get_command_result" ? ["commandId"] : name == "control_recording" ? ["action"] : ["id"]
                    let description = name == "get_agent_setup" ? "只读获取 RecordAI Skill 完整文件、当前连接路径和安装验证说明。不安装、不录音。" : name == "get_recording_status" ? "读取实际采集状态；available=false时不能宣称录音状态已确认。" : name == "get_command_result" ? "读取控制命令回执；accepted仅代表请求已接受，录音状态须另查。" : name == "control_recording" ? "明确要求时控制录音；可用launch=true冷启动。排队成功不是录音成功。" : name == "get_changes" ? "只读变更游标；resyncRequired时重新list" : "只读本机录音与转录。默认不返回未定稿预览。"
                    return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false], "annotations": ["readOnlyHint": name != "control_recording", "destructiveHint": false, "idempotentHint": name != "control_recording", "openWorldHint": false]]
                }]
            case "tools/call":
                do {
                    let name = params["name"] as? String ?? ""
                    guard toolNames.contains(name) else { throw CLIError.message("未知只读工具。") }
                    let args = params["arguments"] as? [String: Any] ?? [:]
                    let value: Any
                    switch name {
                    case "get_agent_setup": value = try setup(store.root).descriptor()
                    case "get_recording_status": value = try runtime(store.root)
                    case "get_command_result": value = try JSONSerialization.jsonObject(with: RecordAIControlQueue.result(uuid(args["commandId"] as? String), root: store.root))
                    case "list_recordings":
                        guard Set(args.keys).isSubset(of: ["query", "groupId", "ungrouped"]),
                              args["query"] == nil || args["query"] is String,
                              args["groupId"] == nil || args["groupId"] is String,
                              args["ungrouped"] == nil || args["ungrouped"] is Bool else { throw CLIError.message("录音筛选参数类型无效。") }
                        let group = try (args["groupId"] as? String).map { try uuid($0) }
                        value = try summaries(store, query: args["query"] as? String ?? "", groupID: group, ungrouped: args["ungrouped"] as? Bool ?? false)
                    case "control_recording":
                        guard let action = args["action"] as? String else { throw CLIError.message("control_recording需要action") }
                        guard RecordAIControlQueue.actions.contains(action) else { throw CLIError.message("不支持的录音控制动作。") }
                        if let launch = args["launch"], !(launch is Bool) { throw CLIError.message("launch必须是布尔值。") }
                        try launchIfRequested(args["launch"] as? Bool ?? false, action: action, root: store.root)
                        let command = try RecordAIControlQueue.enqueue(action: action, root: store.root)
                        value = ["accepted": true, "commandId": command.id.uuidString, "action": action]
                    case "get_changes":
                        guard let since = args["since"] as? Int, since >= 0 else { throw CLIError.message("since必须是非负整数。") }
                        value = try jsonValue(store.changes(since: since))
                    default:
                        let record = try store.read(uuid(args["id"] as? String), includePreview: args["includePreview"] as? Bool ?? false)
                        if name == "get_audio_files" { value = try jsonValue(record.audioFiles) }
                        else if name == "get_transcript" {
                            var transcript: [String: Any] = ["id": record.id.uuidString, "revision": record.revision, "finalText": record.finalText, "paragraphs": try jsonValue(record.paragraphs), "transcriptionReady": record.transcriptionReady, "ready": record.ready]
                            if let preview = record.livePreview { transcript["livePreview"] = preview; transcript["previewIsFinal"] = false }
                            value = transcript
                        } else { value = try jsonValue(record) }
                    }
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
                    result = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false]
                } catch { result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true] }
            case "resources/list":
                result = ["resources": [["uri": "recordai://setup", "name": "RecordAI 安装说明与 Skill", "mimeType": "application/json"]] + (try store.list().map { ["uri": "recordai://recordings/\($0.id.uuidString)", "name": $0.title, "mimeType": "application/json"] })]
            case "resources/read":
                let uri = params["uri"] as? String ?? ""
                if uri == "recordai://setup" {
                    let data = try JSONSerialization.data(withJSONObject: setup(store.root).descriptor(), options: [.sortedKeys, .withoutEscapingSlashes])
                    result = ["contents": [["uri": uri, "mimeType": "application/json", "text": String(decoding: data, as: UTF8.self)]]]
                    break
                }
                let prefix = "recordai://recordings/"
                guard uri.hasPrefix(prefix) else { throw CLIError.message("未知录音资源。") }
                let record = try store.read(uuid(String(uri.dropFirst(prefix.count))))
                result = ["contents": [["uri": uri, "mimeType": "application/json", "text": String(decoding: try AgentCodec.encoder().encode(record), as: UTF8.self)]]]
            default:
                try output(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32601, "message": "Method not found"]]); continue
            }
            try output(["jsonrpc": "2.0", "id": requestID, "result": result])
        } catch {
            try? output(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32602, "message": error.localizedDescription]])
        }
    }
}
var arguments = Array(CommandLine.arguments.dropFirst())
var root = defaultAgentRoot
if let index = arguments.firstIndex(of: "--root") {
    guard arguments.indices.contains(index + 1) else { fputs("--root需要发布目录\n", stderr); exit(2) }
    root = URL(fileURLWithPath: arguments[index + 1]); arguments.removeSubrange(index...index+1)
}
let store = AgentReadStore(root: root)
do {
    switch arguments.first ?? "help" {
    case "setup":
        if arguments.contains("--json") { try output(setup(root).descriptor()) }
        else { print(setup(root).guide) }
    case "status": try output(runtime(root))
    case "result": try output(JSONSerialization.jsonObject(with: RecordAIControlQueue.result(uuid(arguments.count > 1 ? arguments[1] : nil), root: root)))
    case "list":
        var query = "", group: UUID?, ungrouped = false
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--ungrouped" { ungrouped = true; index += 1; continue }
            guard ["--query", "--group"].contains(flag), arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else { throw CLIError.message("不支持的筛选参数或缺少值：\(flag)") }
            if flag == "--query" { query = arguments[index + 1] } else { group = try uuid(arguments[index + 1]) }
            index += 2
        }
        guard !ungrouped || group == nil else { throw CLIError.message("分组和未分组筛选不能同时指定。") }
        try output(summaries(store, query: query, groupID: group, ungrouped: ungrouped))
    case "control":
        guard arguments.count > 1 else { throw CLIError.message("control需要动作名") }
        guard RecordAIControlQueue.actions.contains(arguments[1]) else { throw CLIError.message("不支持的录音控制动作。") }
        try launchIfRequested(arguments.contains("--launch"), action: arguments[1], root: root)
        let command = try RecordAIControlQueue.enqueue(action: arguments[1], root: root)
        try output(["accepted": true, "commandId": command.id.uuidString, "action": command.action])
    case "read", "audio":
        let record = try store.read(uuid(arguments.count > 1 ? arguments[1] : nil), includePreview: arguments.contains("--include-preview"))
        if arguments[0] == "audio" { try output(jsonValue(record.audioFiles)); break }
        let formatIndex = arguments.firstIndex(of: "--format")
        let format = formatIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "json"
        if format == "json" { try output(jsonValue(record)) }
        else {
            let content: String
            switch format { case "md": content = record.markdown; case "txt": content = record.finalText; case "srt": content = record.originalSubtitles
            default: throw CLIError.message("format必须为json、md、txt或srt。") }
            FileHandle.standardOutput.write(Data(content.utf8))
        }
    case "changes":
        guard let index = arguments.firstIndex(of: "--since"), arguments.indices.contains(index + 1), let cursor = Int(arguments[index + 1]), cursor >= 0 else { throw CLIError.message("changes需要--since非负整数。") }
        try output(jsonValue(store.changes(since: cursor)))
    case "mcp": mcp(store)
    case "help", "--help": print("recordai setup [--json] | list | read UUID [--format json|md|txt|srt] [--include-preview] | audio UUID | changes --since N | status | result COMMAND_UUID | control ACTION [--launch] | mcp\n可选 --root 指定AgentData目录。--launch仅用于start_recording和本App默认资料目录。")
    default: throw CLIError.message("未知命令，请使用--help。")
    }
} catch { fputs("读取失败：\(error.localizedDescription)\n", stderr); exit(1) }
