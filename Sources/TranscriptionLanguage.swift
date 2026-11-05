import Foundation

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh", cantonese = "yue", english = "en", automatic = "auto"
    var id: String { rawValue }
    var title: String {
        switch self { case .chinese: return L10n.text("普通话"); case .cantonese: return L10n.text("粤语"); case .english: return L10n.text("英语"); case .automatic: return L10n.text("中英自动") }
    }
    var supportsLivePreview: Bool { true }
    static let preferenceKey = "RecordAI.transcriptionLanguage"
    static var saved: String {
        guard let value = UserDefaults.standard.string(forKey: preferenceKey), Self(rawValue: value) != nil else { return "zh" }
        return value
    }
}
