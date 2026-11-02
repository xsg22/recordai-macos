import Foundation
import Combine

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var name: String {
        switch self { case .system: return L10n.text("跟随系统"); case .simplifiedChinese: return "简体中文"; case .english: return "English" }
    }
}

/// UI-only localization. Callers must not pass transcript, title, group or custom speaker text.
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    @Published var selection: InterfaceLanguage { didSet { defaults.set(selection.rawValue, forKey: Self.preferenceKey) } }
    static let preferenceKey = "RecordAI.interfaceLanguage"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard, initial: InterfaceLanguage? = nil) {
        self.defaults = defaults
        selection = initial ?? ProcessInfo.processInfo.environment["RECORD_AI_UI_LANGUAGE"].flatMap(InterfaceLanguage.init(rawValue:))
            ?? defaults.string(forKey: Self.preferenceKey).flatMap(InterfaceLanguage.init(rawValue:)) ?? .system
    }
    var effective: InterfaceLanguage {
        if selection != .system { return selection }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }
    var locale: Locale { Locale(identifier: effective == .english ? "en" : "zh_Hans_CN") }
}

enum L10n {
    static var locale: Locale { AppLanguage.shared.locale }
    /// Only these compound processing stages contain a system label in a template slot.
    /// Do not recursively translate arbitrary captured values such as filenames or account names.
    static func processingStatus(_ source: String) -> String {
        for stage in ["转录完成", "续录转写已追加", "正在区分发言人", "正在对齐发言人与文字"] where source.hasPrefix(stage + " · ") {
            return text(stage) + text(String(source.dropFirst(stage.count)))
        }
        return text(source)
    }
    private static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "en", withExtension: "json", subdirectory: "Localization"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return catalog
    }()
    private static let prefixes = english.keys.filter { $0.hasSuffix("：") || $0.hasSuffix(" · ") }
        .sorted { $0.count > $1.count }
    static func format(_ key: String, _ values: String...) -> String {
        let template = AppLanguage.shared.effective == .english ? (english[key] ?? key) : key
        let markers = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        var result = "", cursor = template.startIndex
        for match in markers.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range, in: template), let number = Range(match.range(at: 1), in: template),
                  let index = Int(template[number]), values.indices.contains(index) else { continue }
            result += template[cursor..<range.lowerBound]; result += values[index]; cursor = range.upperBound
        }
        return result + template[cursor...]
    }
    private struct Template {
        let pattern: NSRegularExpression
        let translation: String
        let slots: [String]
    }
    // Templates are only for existing system-generated status/error strings. Captured values stay verbatim.
    private static let templates: [Template] = english.keys.filter { $0.contains("{0}") }.sorted { $0.count > $1.count }.compactMap { key in
        let markers = try! NSRegularExpression(pattern: #"\{\d+\}"#)
        let matches = markers.matches(in: key, range: NSRange(key.startIndex..., in: key))
        var expression = "^", cursor = key.startIndex, slots: [String] = []
        for match in matches {
            guard let range = Range(match.range, in: key) else { continue }
            expression += NSRegularExpression.escapedPattern(for: String(key[cursor..<range.lowerBound])) + "(.*?)"
            slots.append(String(key[range])); cursor = range.upperBound
        }
        expression += NSRegularExpression.escapedPattern(for: String(key[cursor...])) + "$"
        guard let pattern = try? NSRegularExpression(pattern: expression, options: .dotMatchesLineSeparators), let translation = english[key] else { return nil }
        return Template(pattern: pattern, translation: translation, slots: slots)
    }
    static func text(_ source: String) -> String {
        guard AppLanguage.shared.effective == .english else { return source }
        if let translated = english[source] { return translated }
        guard source.range(of: #"[\p{Han}]"#, options: .regularExpression) != nil else { return source }
        for prefix in prefixes where source.hasPrefix(prefix) {
            return (english[prefix] ?? prefix) + source.dropFirst(prefix.count)
        }
        for template in templates {
            guard let match = template.pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { continue }
            // One replacement pass prevents a captured filename such as "{1}" being interpreted as a format slot.
            let markers = try! NSRegularExpression(pattern: #"\{\d+\}"#)
            let format = template.translation
            let pieces = markers.matches(in: format, range: NSRange(format.startIndex..., in: format))
            var result = "", cursor = format.startIndex
            for piece in pieces {
                guard let range = Range(piece.range, in: format) else { continue }
                result += format[cursor..<range.lowerBound]
                if let index = template.slots.firstIndex(of: String(format[range])), let value = Range(match.range(at: index + 1), in: source) { result += source[value] }
                else { result += format[range] }
                cursor = range.upperBound
            }
            return result + format[cursor...]
        }
        return source
    }
}
