import Foundation
import Darwin

struct RecordAIRuntimeStatus: Codable {
    var schemaVersion = 1
    var observedAt = Date()
    var processID: Int32 = ProcessInfo.processInfo.processIdentifier
    var recording: Bool
    var paused: Bool
    var preparing: Bool
    var busy: Bool
    var recordingID: UUID?
    var status: String
    var issue: String?
    var available: Bool = true

    static func read(root: URL) throws -> RecordAIRuntimeStatus {
        let url = root.appendingPathComponent("runtime.json")
        try RecordAIControlQueue.requireContained(url, root: root)
        var value = try AgentCodec.decoder().decode(Self.self, from: Data(contentsOf: url))
        value.available = value.schemaVersion == 1 && abs(value.observedAt.timeIntervalSinceNow) < 5 && kill(value.processID, 0) == 0
        return value
    }
}

struct RecordAIControlCommand: Codable {
    var id: UUID
    var action: String
    var createdAt: Date
}

enum RecordAIControlQueue {
    static let actions = ["start_recording", "stop_recording", "pause_recording", "resume_recording", "retry_transcription"]

    static func requireContained(_ url: URL, root: URL) throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            throw NSError(domain: "RecordAIControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "控制目录路径不安全。"])
        }
    }

    static func result(_ id: UUID, root: URL) throws -> Data {
        let url = root.appendingPathComponent("Control/results/\(id.uuidString).json")
        try requireContained(url, root: root)
        return try Data(contentsOf: url)
    }

    static func enqueue(action: String, root: URL) throws -> RecordAIControlCommand {
        guard actions.contains(action) else { throw NSError(domain: "RecordAIControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持的控制动作：\(action)"]) }
        let command = RecordAIControlCommand(id: UUID(), action: action, createdAt: Date())
        let directory = root.appendingPathComponent("Control/commands", isDirectory: true)
        try requireContained(directory, root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(command.id.uuidString).json")
        let data = try AgentCodec.encoder().encode(command)
        try data.write(to: url, options: .atomic)
        return command
    }

    static func pending(root: URL) -> [(URL, RecordAIControlCommand)] {
        let directory = root.appendingPathComponent("Control/commands", isDirectory: true)
        guard (try? requireContained(directory, root: root)) != nil else { return [] }
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard (try? requireContained(url, root: root)) != nil else { return nil }
            guard let command = try? AgentCodec.decoder().decode(RecordAIControlCommand.self, from: Data(contentsOf: url)) else { return nil }
            return (url, command)
        }
    }

    static func finish(_ url: URL, root: URL, result: String, accepted: Bool = true) {
        let completed = root.appendingPathComponent("Control/results", isDirectory: true)
        guard (try? requireContained(completed, root: root)) != nil,
              (try? requireContained(url, root: root)) != nil else { return }
        try? FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        let resultURL = completed.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json")
        let payload: [String: String] = ["status": accepted ? "accepted" : "rejected", "result": result, "finishedAt": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) { try? data.write(to: resultURL, options: .atomic) }
        try? FileManager.default.removeItem(at: url)
    }
}
