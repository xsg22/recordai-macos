import Foundation

enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh", english = "en", automatic = "auto"
    var id: String { rawValue }
    var title: String {
        switch self { case .chinese: return L10n.text("中文"); case .english: return L10n.text("英语"); case .automatic: return L10n.text("中英自动") }
    }
    static let preferenceKey = "RecordAI.transcriptionLanguage"
    static var saved: String {
        guard let value = UserDefaults.standard.string(forKey: preferenceKey), Self(rawValue: value) != nil else { return "zh" }
        return value
    }
}
