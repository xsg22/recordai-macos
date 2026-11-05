import Foundation

/// Copy only non-sensitive preferences from the previous app identity.
enum LegacyPreferencesMigration {
    static let marker = "TalkTuck.legacyPreferencesMigrated.v2"
    static let keyMap = [
        "RecordAI.interfaceLanguage": "TalkTuck.interfaceLanguage",
        "RecordAI.transcriptionLanguage": "TalkTuck.transcriptionLanguage",
        "miniRecorder.origin.v1": "miniRecorder.origin.v1",
        "miniRecorder.pinned.v1": "miniRecorder.pinned.v1",
        "optionalGemma.activeModel.v1": "optionalGemma.activeModel.v1"
    ]

    static func run(destination: UserDefaults, legacyDomain: [String: Any]?) {
        guard !destination.bool(forKey: marker) else { return }
        guard let legacyDomain else { return }
        for (oldKey, newKey) in keyMap where destination.object(forKey: newKey) == nil {
            if let value = legacyDomain[oldKey] { destination.set(value, forKey: newKey) }
        }
        destination.set(true, forKey: marker)
    }

    static func runForInstalledApp() {
        guard Bundle.main.bundleIdentifier == "com.xsg.talktuck" else { return }
        run(destination: .standard, legacyDomain: UserDefaults.standard.persistentDomain(forName: "com.byering.recordai"))
    }
}
