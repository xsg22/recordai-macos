import Foundation

@main struct PersonalHotwordsSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalHotwords(root: root, modelAvailable: { true }, generate: { _, _ in
            "[\"TalkTuck\",\"不存在的名字\",\"TalkTuck\"]"
        })
        store.extract(from: "我们在讨论 TalkTuck 项目。")
        for _ in 0..<100 where store.extracting { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(store.candidates.map(\.word) == ["TalkTuck"] && store.words.isEmpty)
        store.accept(store.candidates[0])
        precondition(store.words == ["TalkTuck"] && store.candidates.isEmpty)
        let loaded = PersonalHotwords(root: root)
        precondition(loaded.words == ["TalkTuck"])
        loaded.add("talktuck")
        precondition(loaded.words.count == 1)
        loaded.remove("TalkTuck")
        precondition(PersonalHotwords(root: root).words.isEmpty)
        let file = root.appendingPathComponent("personal-hotwords.json")
        try Data("broken".utf8).write(to: file)
        let broken = PersonalHotwords(root: root)
        broken.add("TestName")
        let original = try String(contentsOf: file, encoding: .utf8)
        precondition(original == "broken")
        print("personal hotword smoke passed")
    }
}
