import Foundation

enum RecordingProfile: String, CaseIterable, Identifiable {
    case realtime, backgroundRealtime, afterRecording
    var id: String { rawValue }
    var title: String {
        switch self {
        case .realtime: return L10n.text("实时转录")
        case .backgroundRealtime: return L10n.text("后台实时转录")
        case .afterRecording: return L10n.text("仅录音，结束后转录")
        }
    }
    var detail: String {
        switch self {
        case .realtime: return L10n.text("录音时持续显示文字，最小化和隐藏窗口后识别仍会继续。停止并保存后生成定稿、发言人标签和时间对齐。")
        case .backgroundRealtime: return L10n.text("使用 mini 录音条，保持实时识别和保存；随时展开查看正文。")
        case .afterRecording: return L10n.text("使用 mini 录音条；录音时不加载实时模型，停止保存后自动转录。")
        }
    }
    var usesLiveASR: Bool { self != .afterRecording }
    func compact(windowVisible: Bool, expanded: Bool) -> Bool {
        !windowVisible || (self == .backgroundRealtime && !expanded)
    }
}
