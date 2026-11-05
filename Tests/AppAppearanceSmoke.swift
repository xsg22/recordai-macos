import AppKit

@main struct AppAppearanceSmoke {
    @MainActor static func main() {
        let name = "talktuck-appearance-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let previous = NSApplication.shared.appearance
        defer { defaults.removePersistentDomain(forName: name); NSApplication.shared.appearance = previous }
        let settings = AppAppearance(defaults: defaults)
        precondition(settings.selection == .system)
        settings.apply()
        precondition(NSApplication.shared.appearance == nil)
        settings.selection = .light
        precondition(NSApplication.shared.appearance?.name == .aqua)
        precondition(AppAppearance(defaults: defaults).selection == .light)
        settings.selection = .dark
        precondition(NSApplication.shared.appearance?.name == .darkAqua)
        let restored = AppAppearance(defaults: defaults)
        precondition(restored.selection == .dark)
        restored.selection = .system
        precondition(NSApplication.shared.appearance == nil)
        defaults.set("invalid", forKey: AppAppearance.preferenceKey)
        precondition(AppAppearance(defaults: defaults).selection == .system)
        print("PASS: appearance defaults, native override, persistence and return to system")
    }
}
