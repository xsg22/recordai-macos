import Foundation

@main
struct LiveSessionLifecycleSmoke {
    static func main() async throws {
        let start = Date()
        let session = LiveTranscriptionSession()
        try session.start(model: URL(fileURLWithPath: "/unused-test-model"), executable: URL(fileURLWithPath: "/usr/bin/true"), language: "zh")
        for _ in 0..<15 { session.append([Float](repeating: 0, count: 1600)) }
        async let first: Void = session.finish()
        async let second: Void = session.finish()
        _ = await (first, second)
        precondition(Date().timeIntervalSince(start) < 5, "提前退出的worker不应让finish等待15秒")
        session.cancel()
        await session.finish()
        print("PASS: worker提前退出/管道关闭不会终止App，finish与cancel可安全收口。")
    }
}
