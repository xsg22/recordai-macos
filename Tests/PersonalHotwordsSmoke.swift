import Foundation

@main struct PersonalHotwordsSmoke {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(UUID().uuidString)
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
        var changes = 0
        loaded.onWordsChanged = { changes += 1 }
        precondition(loaded.addBatch("TalkTuck， 星曜计划\nQwen3-ASR；talktuck;Mac Studio"))
        precondition(loaded.words == ["TalkTuck", "星曜计划", "Qwen3-ASR", "Mac Studio"] && changes == 1)
        precondition(PersonalHotwords(root: root).words == loaded.words)
        precondition(!loaded.addBatch("TalkTuck, new term, x"))
        precondition(loaded.words.count == 4 && changes == 1)
        precondition(!loaded.addBatch("talktuck; 星曜计划"))
        precondition(loaded.words.count == 4 && changes == 1)
        let full = PersonalHotwords(root: root.appendingPathComponent("full"))
        let many = (0..<1000).map { "term\($0)" }.joined(separator: "\n")
        precondition(full.addBatch(many) && full.words.count == 1000)
        precondition(!full.addBatch("term1001"))
        precondition(PersonalHotwords(root: root.appendingPathComponent("full")).words.count == 1000)
        let candidates = PersonalHotwords(root: root.appendingPathComponent("candidate-filter"), modelAvailable: { true }, generate: { _, _ in
            "[\"系统\",\"暂停\",\"继续\",\"今天进行录音验收\",\"张三\",\"杭州\",\"阿里巴巴\",\"TalkTuck\",\"星光\"]"
        })
        candidates.extract(from: "今天进行录音验收，检查系统，暂停后继续。张三在杭州使用阿里巴巴和 TalkTuck，参与星光项目。")
        for _ in 0..<100 where candidates.extracting { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(candidates.candidates.map(\.word) == ["张三", "杭州", "阿里巴巴", "TalkTuck", "星光"])
        let oldRoot = root.appendingPathComponent("legacy-candidates")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        let oldCandidates = ["系统", "暂停", "张三"].map { ["id": UUID().uuidString, "word": $0, "context": "测试"] }
        let oldData: [String: Any] = ["words": ["系统"], "candidates": oldCandidates]
        try JSONSerialization.data(withJSONObject: oldData).write(to: oldRoot.appendingPathComponent("personal-hotwords.json"))
        let oldStore = PersonalHotwords(root: oldRoot)
        precondition(oldStore.words == ["系统"] && oldStore.candidates.map(\.word) == ["张三"])
        let file = root.appendingPathComponent("personal-hotwords.json")
        try Data("broken".utf8).write(to: file)
        let broken = PersonalHotwords(root: root)
        broken.add("TestName")
        let original = try String(contentsOf: file, encoding: .utf8)
        precondition(original == "broken")
        print("personal hotword smoke passed")
    }
}
