import Foundation
import AVFoundation

/// Synthetic data for the existing CLI/MCP assertions. Never loads a user library.
@main struct AgentCLIFixture {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let library = try MeetingLibrary(root: root)
        var record = MeetingRecord(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                                   title: "CLI fixture", text: "你好，世界！", duration: 1,
                                   notes: "旧笔记", summary: "旧总结", status: .completed, previewText: "Synthetic live preview")
        let directory = library.directory(for: record.id).appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        memset(buffer.floatChannelData![0], 0, 16000 * MemoryLayout<Float>.size)
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        record.audioFiles = [url.lastPathComponent]; record.audioDurations = [url.lastPathComponent: 1]
        _ = try library.save(record)
        let published = try AgentReadStore(root: root.appendingPathComponent("AgentData")).read(record.id)
        precondition(published.ready)
        print("PASS: isolated CLI fixture prepared")
    }
}

/// A second client creates the concurrent edit expected by LibrarySyncSmoke.
/// The caller must supply the isolated loopback fixture used for the seed phase.
struct LibrarySyncRemoteEditSmoke {
    @MainActor static func main() async throws {
        let server = URL(string: CommandLine.arguments[1])!
        precondition(server.host == "127.0.0.1")
        var request = URLRequest(url: server.appendingPathComponent("v1/auth/account"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": "qa_sync_bridge", "password": "synthetic-password"])
        let (data, response) = try await URLSession.shared.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        let token = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["token"] as! String
        let client = LibrarySyncHTTP(server: server, token: token)
        let page = try await client.changes(cursor: nil)
        let entry = page.events.last { $0.id == LibrarySyncSmoke.recordingID }!
        var record = entry.value!.recording!
        record.title = "iPhone 修改标题"
        record.paragraphs[0].text = "iPhone 修改的正式文字"
        let changed = try await client.mutate(deviceId: UUID(), mutation: LibrarySyncMutation(kind: .recording, id: record.id, baseVersion: entry.version, value: .recording(record)))
        precondition(changed.status == "applied")
        let groupEntry = page.events.last { $0.id == record.groupId && $0.kind == .group }!
        var group = groupEntry.value!.group!; group.name = "项目·手机"
        let renamed = try await client.mutate(deviceId: UUID(), mutation: LibrarySyncMutation(kind: .group, id: group.id, baseVersion: groupEntry.version, value: .group(group)))
        precondition(renamed.status == "applied")
        print("PASS: second loopback client changed text and group while Mac edits remained offline")
    }
}
