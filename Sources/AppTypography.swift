import SwiftUI

/// macOS 使用系统字体（中文由系统匹配），按会议阅读任务提供清晰的字号层级。
/// 这些是产品字号，不冒充Apple规定的统一最低字号；系统控件仍保持原生键鼠与焦点行为。
enum AppTypography {
    static let body = Font.system(size: 15)
    static let secondary = Font.system(size: 13)
    static let heading = Font.system(size: 16, weight: .semibold)
    static let transcript = Font.system(size: 18)
    static let sidebar = Font.system(size: 15, weight: .medium)
}

/// Shared meeting metadata for the library and recovery views.
func recordingDurationText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0 秒" }
    if seconds < 60 { return "\(Int(seconds)) 秒" }
    let minutes = Int(min(seconds / 60, Double(Int.max / 2)))
    return minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分钟" : "\(minutes) 分钟"
}

struct RecordAIPrimaryButtonStyle: ButtonStyle {
    var showsProgress = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 13)
            .foregroundStyle(.white)
            .background(enabled || showsProgress ? RecordAITheme.primaryFill.opacity(configuration.isPressed ? 0.8 : 1) : Color.gray.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
