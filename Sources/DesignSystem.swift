import AppKit
import SwiftUI

/// Shared values from Docs/design-v2/manifest.json.
enum RecordAITheme {
    static let primaryFill = Color(red: 9 / 255, green: 99 / 255, blue: 1)
    static let accent = adaptive(light: 0x0963ff, dark: 0x94bcff)
    static let radius: CGFloat = 12
    static let sidebar = adaptive(light: 0xf5f7fb, dark: 0x131c2d)
    static let surface = adaptive(light: 0xffffff, dark: 0x182133)
    static let ink = adaptive(light: 0x172033, dark: 0xe7edf8)
    static let muted = adaptive(light: 0x788296, dark: 0x9caac1)
    static let border = adaptive(light: 0xe6e9ef, dark: 0x2c374c)
    static let waveformRest = adaptive(light: 0xb8c7d9, dark: 0xa4b4cd)
    static let tabs = adaptive(light: 0xf2f4f8, dark: 0x101a2b)
    static let avatar = Color(red: 230/255, green: 237/255, blue: 250/255)
    static let quiet = adaptive(light: 0xf5f7fb, dark: 0x222e44)
    static let selection = adaptive(light: 0xe3edff, dark: 0x20395f)
    static let selectionInk = adaptive(light: 0x12315b, dark: 0x94bcff)
    static let waveStart = adaptive(light: 0xf0f6ff, dark: 0x202d46)
    static let waveEnd = adaptive(light: 0xf7f8fb, dark: 0x202d46)
    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

struct RecordAILogo: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    var size: CGFloat = 44
    var body: some View {
        Group {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().scaleEffect(1.2)
            } else {
                Image(systemName: "waveform").font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white).frame(width: size, height: size)
                    .background(Color(red: 0.03, green: 0.08, blue: 0.23), in: RoundedRectangle(cornerRadius: size * 0.24))
            }
        }.frame(width: size, height: size).clipped().accessibilityLabel("RecordAI")
    }
}

struct RecordAISecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 11)
            .foregroundStyle(enabled ? RecordAITheme.ink.opacity(0.8) : RecordAITheme.muted.opacity(0.55))
            .background(configuration.isPressed ? RecordAITheme.quiet : RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(RecordAITheme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct RecordAICard<Content: View>: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    var quiet = false
    var spacing: CGFloat = 16
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(quiet ? RecordAITheme.quiet : RecordAITheme.surface, in: RoundedRectangle(cornerRadius: RecordAITheme.radius))
            .overlay(RoundedRectangle(cornerRadius: RecordAITheme.radius).stroke(quiet ? .clear : RecordAITheme.border, lineWidth: 1))
    }
}

struct RecordAIPageHeader<Trailing: View>: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let title: String
    var subtitle = ""
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 24, weight: .semibold))
                if !subtitle.isEmpty { Text(subtitle).font(AppTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing
        }.padding(.bottom, 18)
    }
}

struct RecordAISettingRow<Content: View>: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let title: String
    var minimumHeight: CGFloat = 62
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 20) {
            Text(title).font(AppTypography.body)
            Spacer(minLength: 20)
            content.frame(maxWidth: 190)
        }.padding(.vertical, 8).frame(minHeight: minimumHeight)
    }
}

struct RecordAIInfo: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let text: String
    var warning = false
    var success = false
    private var color: Color { warning ? .orange : success ? .green : RecordAITheme.accent }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: warning ? "exclamationmark.triangle" : success ? "checkmark.circle" : "info.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.font(AppTypography.secondary).foregroundStyle(color)
            .padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct RecordAISegmentedPicker<Value: Hashable>: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let items: [(String, Value)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Button { selection = item.1 } label: {
                    Text(item.0).font(AppTypography.secondary.weight(selection == item.1 ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(selection == item.1 ? RecordAITheme.accent : .secondary)
                        .background(selection == item.1 ? RecordAITheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityValue(L10n.text(selection == item.1 ? "已选择" : "未选择"))
            }
        }.padding(4).background(RecordAITheme.tabs, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A menu keeps native keyboard navigation while matching the design's field surface.
struct RecordAIChoicePicker<Value: Hashable>: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let title: String
    let items: [(String, Value)]
    @Binding var selection: Value
    var body: some View {
        Menu {
            ForEach(items.indices, id: \.self) { i in
                Button { selection = items[i].1 } label: {
                    if selection == items[i].1 { Label(items[i].0, systemImage: "checkmark") }
                    else { Text(items[i].0) }
                }
            }
        } label: {
            Text(items.first { $0.1 == selection }?.0 ?? title).font(AppTypography.secondary)
        }.menuStyle(.borderlessButton).menuIndicator(.visible)
            .tint(RecordAITheme.ink).foregroundStyle(RecordAITheme.ink)
            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RecordAITheme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(RecordAITheme.border))
            .accessibilityLabel(L10n.text(title))
    }
}
