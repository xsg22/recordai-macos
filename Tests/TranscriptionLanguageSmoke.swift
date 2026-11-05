import Foundation
@main struct TranscriptionLanguageSmoke {
    @MainActor static func main() {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: TranscriptionLanguage.preferenceKey)
        defer {
            if let old { defaults.set(old, forKey: TranscriptionLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: TranscriptionLanguage.preferenceKey) }
        }
        defaults.removeObject(forKey: TranscriptionLanguage.preferenceKey)
        precondition(TranscriptionLanguage.saved == "zh")
        defaults.set("yue", forKey: TranscriptionLanguage.preferenceKey)
        precondition(TranscriptionLanguage.saved == "yue")
        defaults.set("invalid", forKey: TranscriptionLanguage.preferenceKey)
        precondition(TranscriptionLanguage.saved == "zh")
        precondition(TranscriptionLanguage.allCases.map(\.rawValue) == ["zh","yue","en","auto"])
        precondition(RecordingSpeechLanguage.allCases.map(\.rawValue) == ["zh","yue","en"])
        precondition(TranscriptionLanguage.cantonese.supportsLivePreview)
        precondition(TranscriptionLanguage.chinese.supportsLivePreview && TranscriptionLanguage.english.supportsLivePreview && TranscriptionLanguage.automatic.supportsLivePreview)
        precondition(RecordingSpeechLanguage.cantonese.appleLocale.language.languageCode?.identifier == "yue")
        precondition(!RecordingSpeechLanguage.cantonese.allowsBilingualFallback)
        precondition(RecordingSpeechLanguage.english.allowsBilingualFallback)
        print("PASS: shared Mandarin/Cantonese/English codes; Mac auto retained; Cantonese live enabled; unsupported phone fallback remains explicit")
    }
}
