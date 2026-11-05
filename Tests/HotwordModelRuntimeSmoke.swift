import Foundation

enum TranscriptionError: LocalizedError { case message(String) }
enum ASRResources {
    static var root: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CoHearTranscribe/Models/ASR") }
    static func executable(_ name: String) -> URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("Engine/ASR/"+name)
        return url.flatMap { FileManager.default.isExecutableFile(atPath:$0.path) ? $0 : nil }
    }
}
@main struct HotwordModelRuntimeSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = "今天薛圣国讨论了 RecordAI 项目，TalkTuck 是 Mac 客户端。接下来会检查 Qwen3-ASR 的热词。"
        let store = PersonalHotwords(root:root)
        guard HotwordLocalRuntime.configurationAvailable() else { fatalError("model or engine missing") }
        store.extract(from:source)
        for _ in 0..<600 where store.extracting { try await Task.sleep(nanoseconds:100_000_000) }
        guard !store.extracting else { fatalError("model timed out") }
        let words = Set(store.candidates.map(\.word))
        precondition(words.contains("RecordAI") && words.contains("TalkTuck"), "extraction missed known terms: \(store.status)")
        precondition(words.allSatisfy { source.contains($0) } && store.words.isEmpty)
        store.accept(store.candidates.first { $0.word == "RecordAI" }!)
        precondition(store.words == ["RecordAI"])
        print("PASS: real local model extracted candidates offline; confirmed word persisted")
    }
}
