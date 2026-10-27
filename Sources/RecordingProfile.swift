import Foundation

enum RecordingProfile: String, CaseIterable, Identifiable {
    case realtime, backgroundRealtime, afterRecording
    var id: String { rawValue }
    var title: String {
        switch self {
        case .realtime: return "实时转录（默认）"
        case .backgroundRealtime: return "后台实时转录"
        case .afterRecording: return "仅录音，结束后转录"
        }
    }
    var detail: String {
        switch self {
        case .realtime: return "录音时持续显示文字；最小化或隐藏窗口后自动减少界面刷新，识别继续。"
        case .backgroundRealtime: return "使用 mini 录音条，保持实时识别和保存；随时展开查看正文。"
        case .afterRecording: return "使用 mini 录音条；录音时不加载实时模型，停止保存后自动转录。"
        }
    }
    var usesLiveASR: Bool { self != .afterRecording }
    func compact(windowVisible: Bool, expanded: Bool) -> Bool {
        !windowVisible || (self == .backgroundRealtime && !expanded)
    }
}
