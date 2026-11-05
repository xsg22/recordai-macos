import Foundation

@main struct LegacyPreferencesMigrationSmoke {
    static func main() {
        let name = "talktuck-migration-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        LegacyPreferencesMigration.run(destination: defaults, legacyDomain: nil)
        precondition(!defaults.bool(forKey: LegacyPreferencesMigration.marker), "a missing old domain must remain retryable")
        defaults.set("en", forKey: "TalkTuck.interfaceLanguage")
        let legacy: [String: Any] = ["RecordAI.interfaceLanguage": "zh-Hans", "RecordAI.transcriptionLanguage": "en", "miniRecorder.pinned.v1": false, "secret": "do-not-copy"]
        LegacyPreferencesMigration.run(destination: defaults, legacyDomain: legacy)
        precondition(defaults.string(forKey: "TalkTuck.interfaceLanguage") == "en", "existing preference must win")
        precondition(defaults.string(forKey: "TalkTuck.transcriptionLanguage") == "en", "old language must map to the current key")
        precondition(defaults.object(forKey: "miniRecorder.pinned.v1") as? Bool == false)
        precondition(defaults.object(forKey: "secret") == nil)
        defaults.removeObject(forKey: "TalkTuck.transcriptionLanguage")
        LegacyPreferencesMigration.run(destination: defaults, legacyDomain: legacy)
        precondition(defaults.object(forKey: "TalkTuck.transcriptionLanguage") == nil, "migration must run only once")
        print("PASS: legacy settings map to current keys, preserve new values, and run once")
    }
}
