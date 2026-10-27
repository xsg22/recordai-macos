import Foundation

func jsonValue<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: AgentCodec.encoder().encode(value), options: [.fragmentsAllowed]) }
func output(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
}
func summaries(_ store: AgentReadStore) throws -> [[String: Any]] {
    try store.list().map { ["id": $0.id.uuidString, "title": $0.title, "status": $0.status, "revision": $0.revision,
        "transcriptionReady": $0.transcriptionReady, "ready": $0.ready, "speakerAnalysisStatus": $0.speakerAnalysisStatus] }
}
func uuid(_ value: String?) throws -> UUID {
    guard let value, let id = UUID(uuidString: value) else { throw CLIError.message("需要有效的录音UUID。") }; return id
}
enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
let toolNames = ["list_recordings", "get_recording", "get_transcript", "get_audio_files", "get_changes", "control_recording"]
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
                result = ["protocolVersion": supported.contains(requested) ? requested : "2025-03-26", "capabilities": ["tools": [:], "resources": [:]], "serverInfo": ["name": "recordai", "version": "0.15.1"]]
            case "ping": result = [:] as [String: String]
            case "tools/list":
                result = ["tools": toolNames.map { name -> [String: Any] in
                    let properties: [String: Any] = name == "get_changes" ? ["since": ["type": "integer", "minimum": 0]] : name == "list_recordings" ? [:] : name == "control_recording" ? ["action": ["type": "string", "enum": RecordAIControlQueue.actions]] : ["id": ["type": "string", "format": "uuid"], "includePreview": ["type": "boolean", "default": false]]
                    let required: [String] = name == "get_changes" ? ["since"] : name == "list_recordings" ? [] : name == "control_recording" ? ["action"] : ["id"]
                    let description = name == "control_recording" ? "控制本机RecordAI录音。命令写入本机队列，由App异步执行。" : name == "get_changes" ? "只读变更游标；resyncRequired时重新list" : "只读本机录音与转录。默认不返回未定稿预览。"
                    return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false], "annotations": ["readOnlyHint": name != "control_recording", "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
                }]
            case "tools/call":
                do {
                    let name = params["name"] as? String ?? ""
                    guard toolNames.contains(name) else { throw CLIError.message("未知只读工具。") }
                    let args = params["arguments"] as? [String: Any] ?? [:]
                    let value: Any
                    switch name {
                    case "list_recordings": value = try summaries(store)
                    case "control_recording":
                        guard let action = args["action"] as? String else { throw CLIError.message("control_recording需要action") }
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
                result = ["resources": try store.list().map { ["uri": "recordai://recordings/\($0.id.uuidString)", "name": $0.title, "mimeType": "application/json"] }]
            case "resources/read":
                let uri = params["uri"] as? String ?? ""
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
var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CoHearTranscribe/AgentData")
if let index = arguments.firstIndex(of: "--root") {
    guard arguments.indices.contains(index + 1) else { fputs("--root需要发布目录\n", stderr); exit(2) }
    root = URL(fileURLWithPath: arguments[index + 1]); arguments.removeSubrange(index...index+1)
}
let store = AgentReadStore(root: root)
do {
    switch arguments.first ?? "help" {
    case "list": try output(summaries(store))
    case "control":
        guard arguments.count > 1 else { throw CLIError.message("control需要动作名") }
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
    case "help", "--help": print("recordai list | read UUID [--format json|md|txt|srt] [--include-preview] | audio UUID | changes --since N | control ACTION | mcp\n可选 --root 指定AgentData目录。")
    default: throw CLIError.message("未知命令，请使用--help。")
    }
} catch { fputs("读取失败：\(error.localizedDescription)\n", stderr); exit(1) }
