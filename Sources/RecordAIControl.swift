import Foundation

struct RecordAIControlCommand: Codable {
    var id: UUID
    var action: String
    var createdAt: Date
}

enum RecordAIControlQueue {
    static let actions = ["start_recording", "stop_recording", "pause_recording", "resume_recording", "retry_transcription"]

    static func enqueue(action: String, root: URL) throws -> RecordAIControlCommand {
        guard actions.contains(action) else { throw NSError(domain: "RecordAIControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持的控制动作：\(action)"]) }
        let command = RecordAIControlCommand(id: UUID(), action: action, createdAt: Date())
        let directory = root.appendingPathComponent("Control/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(command.id.uuidString).json")
        let data = try AgentCodec.encoder().encode(command)
        try data.write(to: url, options: .atomic)
        return command
    }

    static func pending(root: URL) -> [(URL, RecordAIControlCommand)] {
        let directory = root.appendingPathComponent("Control/commands", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let command = try? AgentCodec.decoder().decode(RecordAIControlCommand.self, from: Data(contentsOf: url)) else { return nil }
            return (url, command)
        }
    }

    static func finish(_ url: URL, root: URL, result: String) {
        let completed = root.appendingPathComponent("Control/results", isDirectory: true)
        try? FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        let resultURL = completed.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json")
        let payload: [String: String] = ["status": "accepted", "result": result, "finishedAt": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) { try? data.write(to: resultURL, options: .atomic) }
        try? FileManager.default.removeItem(at: url)
    }
}
