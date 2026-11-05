import Foundation

@main struct LegacyPreferencesMigrationSmoke {
    static func main() {
        let name = "talktuck-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("en", forKey: "RecordAI.interfaceLanguage")
        let legacy: [String: Any] = ["RecordAI.interfaceLanguage": "zh-Hans", "RecordAI.transcriptionLanguage": "en", "miniRecorder.pinned.v1": false, "secret": "do-not-copy"]
        LegacyPreferencesMigration.run(destination: defaults, legacyDomain: legacy)
        precondition(defaults.string(forKey: "RecordAI.interfaceLanguage") == "en")
        precondition(defaults.string(forKey: "RecordAI.transcriptionLanguage") == "en")
        precondition(defaults.object(forKey: "miniRecorder.pinned.v1") as? Bool == false)
        precondition(defaults.object(forKey: "secret") == nil)
        defaults.removeObject(forKey: "RecordAI.transcriptionLanguage")
        LegacyPreferencesMigration.run(destination: defaults, legacyDomain: legacy)
        precondition(defaults.object(forKey: "RecordAI.transcriptionLanguage") == nil)
        print("PASS: legacy settings migration preserves new values, limits keys and runs once")
    }
}
