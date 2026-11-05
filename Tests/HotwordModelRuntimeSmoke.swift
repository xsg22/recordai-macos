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
        let source = "今天讨论了 Aurora 项目，TalkTuck 是 Mac 客户端。接下来会检查 Qwen3-ASR 的热词。"
        let store = PersonalHotwords(root:root)
        guard HotwordLocalRuntime.configurationAvailable() else { fatalError("model or engine missing") }
        store.extract(from:source)
        for _ in 0..<600 where store.extracting { try await Task.sleep(nanoseconds:100_000_000) }
        guard !store.extracting else { fatalError("model timed out") }
        let words = Set(store.candidates.map(\.word))
        precondition(words.contains("Aurora") && words.contains("TalkTuck"), "extraction missed known terms: \(store.status)")
        precondition(words.allSatisfy { source.contains($0) } && store.words.isEmpty)
        store.accept(store.candidates.first { $0.word == "Aurora" }!)
        precondition(store.words == ["Aurora"])
        let generic = PersonalHotwords(root: root.appendingPathComponent("generic"))
        generic.extract(from:"今天进行录音验收，首先检查系统声音，再检查暂停和继续。结束以后，检查正式文字分组和同步结果。")
        for _ in 0..<600 where generic.extracting { try await Task.sleep(nanoseconds:100_000_000) }
        precondition(!generic.extracting && generic.candidates.isEmpty, "ordinary recording terms should not be candidates: \(generic.candidates.map(\.word))")
        let mixed = PersonalHotwords(root: root.appendingPathComponent("mixed"))
        mixed.extract(from:"这次要Codex。张三，李四。万物。还有小猫钓鱼。王五。系统声音暂停继续，正式文字同步。")
        for _ in 0..<600 where mixed.extracting { try await Task.sleep(nanoseconds:100_000_000) }
        let names = Set(mixed.candidates.map(\.word))
        precondition(!mixed.extracting && names.contains("张三") && names.contains("李四"))
        precondition(names.isDisjoint(with: ["万物", "系统", "暂停", "继续", "正式", "文字", "同步"]))
        let entities = PersonalHotwords(root: root.appendingPathComponent("entities"))
        entities.extract(from:"今天薛圣国与张三在杭州，和阿里巴巴的李四讨论星光项目和 TalkTuck 产品。")
        for _ in 0..<600 where entities.extracting { try await Task.sleep(nanoseconds:100_000_000) }
        let named = Set(entities.candidates.map(\.word))
        precondition(!entities.extracting && named.isSuperset(of: ["薛圣国", "杭州", "阿里巴巴", "TalkTuck"]))
        print("PASS: real local model extracted candidates offline; confirmed word persisted")
    }
}
