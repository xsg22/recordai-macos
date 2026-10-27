import Foundation
@main struct OptionalModelTransferSmoke {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohear-transfer-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download.partial")
        let job = OptionalModelDownload(destination: destination, expectedBytes: 262144, onProgress: { _ in })
        let result = try await job.fetch(URL(string: base + "/model")!)
        let received = try Data(contentsOf: result)
        precondition(received.count == 262144)
        let cancelled = OptionalModelDownload(destination: root.appendingPathComponent("cancelled"), expectedBytes: 262144, onProgress: { _ in })
        cancelled.cancel()
        do { _ = try await cancelled.fetch(URL(string: base + "/model")!); fatalError("取消必须结束") } catch is CancellationError { }
        let missing = OptionalModelDownload(destination: root.appendingPathComponent("missing"), expectedBytes: 262144, onProgress: { _ in })
        do { _ = try await missing.fetch(URL(string: base + "/missing")!); fatalError("404不能成功") } catch is OptionalModelError { }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
        print("PASS: 本机HTTP真实下载/大小校验/取消/404不安装。未访问真实模型站点。")
    }
}
