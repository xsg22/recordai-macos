import AppKit
import Combine

enum InterfaceAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .light: return L10n.text("浅色")
        case .dark: return L10n.text("深色")
        }
    }
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}

/// An application-level override also covers native panels and the mini window.
@MainActor final class AppAppearance: ObservableObject {
    static let shared = AppAppearance()
    static let preferenceKey = "TalkTuck.appearance"
    private let defaults: UserDefaults
    @Published var selection: InterfaceAppearance {
        didSet {
            defaults.set(selection.rawValue, forKey: Self.preferenceKey)
            apply()
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.preferenceKey).flatMap(InterfaceAppearance.init(rawValue:)) ?? .system
    }
    func apply() {
        NSApplication.shared.appearance = selection.appearanceName.flatMap(NSAppearance.init(named:))
    }
}
