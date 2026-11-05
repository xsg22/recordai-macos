import Foundation

/// Copies non-sensitive preferences once; recordings and models remain in their existing directory.
enum LegacyPreferencesMigration {
    static let marker = "TalkTuck.legacyPreferencesMigrated.v1"
    static let keys = ["RecordAI.interfaceLanguage", "RecordAI.transcriptionLanguage",
                       "miniRecorder.origin.v1", "miniRecorder.pinned.v1", "optionalGemma.activeModel.v1"]

    static func run(destination: UserDefaults, legacyDomain: [String: Any]?) {
        guard !destination.bool(forKey: marker) else { return }
        if let legacyDomain {
            for key in keys where destination.object(forKey: key) == nil {
                if let value = legacyDomain[key] { destination.set(value, forKey: key) }
            }
        }
        destination.set(true, forKey: marker)
    }

    static func runForInstalledApp() {
        guard Bundle.main.bundleIdentifier == "com.xsg.talktuck" else { return }
        run(destination: .standard, legacyDomain: UserDefaults.standard.persistentDomain(forName: "com.byering.recordai"))
    }
}
