import Foundation

/// 不将录音、保存、推理和远端写入混成一个不可操作的“仍有任务”。
enum QuitActivity: Equatable {
    case idle, recording, transcribing, saving, recovering, external
    static func resolve(recording: Bool, preparing: Bool, transcribing: Bool, recovering: Bool = false, externalTask: Bool) -> Self {
        if recovering { return .recovering }
        if externalTask { return .external }
        if preparing { return .saving }
        if recording { return .recording }
        if transcribing { return .transcribing }
        return .idle
    }
    var title: String {
        switch self {
        case .idle: return "退出倾听转录"
        case .recording: return "保存当前录音后退出？"
        case .transcribing: return "取消转录并退出？"
        case .saving: return "正在准备或保存录音"
        case .recovering: return "正在恢复录音"
        case .external: return "正在处理账号或同步任务"
        }
    }
    var detail: String {
        switch self {
        case .recording: return "停止采集并保存完整音频后退出，本次不等待最终转录。下次打开可继续转录；保存失败会留在应用中。"
        case .transcribing: return "音频和已有正文会保留。等待转录任务取消并保存后退出，下次打开可重试未完成片段。"
        case .recovering: return "请等待恢复保存完成，或在恢复窗口取消后再退出；原始音轨会保留。"
        case .saving: return "请等待当前准备或保存步骤结束后再退出，以免中断音频落盘。"
        case .external: return "请等待同步完成，或在账号页面取消当前授权操作后再退出，避免无法确认远端文档是否已创建。"
        case .idle: return "已保存本机资料。"
        }
    }
    var action: String? {
        switch self {
        case .recording: return "保存录音并退出"
        case .transcribing: return "取消转录并退出"
        default: return nil
        }
    }
}
