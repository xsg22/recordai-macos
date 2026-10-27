import Foundation

final class LiveEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LiveTranscriptEvent] = []
    func append(_ value: LiveTranscriptEvent) { lock.lock(); values.append(value); lock.unlock() }
    var all: [LiveTranscriptEvent] { lock.lock(); defer { lock.unlock() }; return values }
}

@main
struct LiveSessionSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("engine model pcm") }
        let raw = try Data(contentsOf: URL(fileURLWithPath: args[3]))
        var samples = [Float](repeating: 0, count: raw.count / 4)
        _ = samples.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
        let collector = LiveEvents()
        let session = LiveTranscriptionSession()
        session.onEvent = { collector.append($0) }
        try session.start(model: URL(fileURLWithPath: args[2]), executable: URL(fileURLWithPath: args[1]), language: "zh")
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            session.append(Array(samples[offset..<min(offset + 1600, samples.count)]))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        precondition(collector.all.contains { $0.type == "partial" && !$0.text.isEmpty }, "停止前必须输出partial")
        await session.finish()
        let events = collector.all
        precondition(events.contains { $0.type == "commit" && !$0.text.isEmpty })
        precondition(events.last?.type == "done")
        precondition(!events.contains { $0.type == "error" })
        print("PASS: Swift常驻worker管道实时输出、EOF尾段、正常退出、无错误事件。")
    }
}
