import Foundation
@main struct TranscriptionLanguageSmoke {
    @MainActor static func main() {
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
