import AppKit
import Foundation

@main struct MiniRecordingSmoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let dragContainer = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        let drag = MiniWindowDragView(frame: NSRect(x: 20, y: 10, width: 525, height: 76))
        dragContainer.addSubview(drag)
        drag.excludedRects = [NSRect(x: 300, y: 14, width: 30, height: 32)]
        for point in [NSPoint(x: 262, y: 3), NSPoint(x: 262, y: 73), NSPoint(x: 3, y: 38), NSPoint(x: 522, y: 38), NSPoint(x: 200, y: 38)] {
            precondition(drag.hitTest(drag.convert(point, to: dragContainer)) === drag, "四边空白和非交互内容都能拖动")
        }
        let controlPoint = drag.convert(NSPoint(x: 315, y: 30), to: dragContainer)
        precondition(drag.hitTest(controlPoint) == nil, "按钮事件必须透传，不能变成窗口拖动")
        drag.excludedRects = [NSRect(x: 14, y: 72, width: 497, height: 65)]
        precondition(drag.hitTest(controlPoint) === drag, "布局变化后旧控件位置重新可拖动")
        drag.setFrameSize(NSSize(width: 525, height: 168))
        precondition(drag.hitTest(drag.convert(NSPoint(x: 250, y: 100), to: dragContainer)) == nil, "错误提示中的文字与按钮事件透传")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cohear-mini-" + UUID().uuidString)
        let namespace = "mini-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: namespace)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: namespace)
        }
        let state = AppState(storageURL: root, connectionNamespace: namespace)
        state.error = nil
        let main = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        state.mainWindow = main
        let controller = MiniRecordingController(state: state, defaults: defaults)
        state.recordingProfile = .afterRecording
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(state.miniMode && controller.panel?.isVisible == true, "选择仅录音进入 mini")
        precondition(!state.recording && !state.preparing && !state.busy, "模式选择不能偷偷启动采集")
        precondition(state.activeRecordingProfile == .realtime && state.liveEnabled, "待开始不修改活动会话")
        state.prepareRecordingProfile(); state.recording = true; state.elapsed = 32
        let previousLive = state.liveEnabled
        state.showRecordingWindow()
        precondition(!state.miniMode && controller.panel?.isVisible == false && state.expandedRealtime)
        precondition(state.recording && state.elapsed == 32 && state.liveEnabled == previousLive, "展开不改变采集、计时或ASR")
        state.showMiniRecorder(); state.hideMiniToMenuBar()
        precondition(state.miniMode && controller.panel?.isVisible == false && !state.miniWindowVisible)
        precondition(state.recording && !state.liveEnabled, "收起到菜单栏保留纯录音会话")
        state.showMiniRecorder(); controller.panel?.performClose(nil)
        precondition(state.recording, "关闭面板不停止会话")
        state.recording = false
        state.recordingProfile = .backgroundRealtime
        try await Task.sleep(nanoseconds: 100_000_000)
        state.prepareRecordingProfile(); state.recording = true
        state.showRecordingWindow(); state.showMiniRecorder()
        precondition(state.liveEnabled && state.activeRecordingProfile == .backgroundRealtime, "切换窗口不关闭实时模型")
        state.recordingIssue = "测试：输入设备已断开，录音已暂停"
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(controller.panel?.frame.height == 168, "异常展开且保留处理空间")
        state.recordingIssue = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(controller.panel?.frame.height == 76)
        let pinned = controller.pinned; controller.togglePinned()
        precondition(controller.pinned != pinned && defaults.bool(forKey: "miniRecorder.pinned.v1") == !pinned)
        let visible = NSRect(x: -1600, y: 0, width: 1600, height: 900)
        let fitted = MiniRecordingController.constrainedFrame(NSRect(x: 5000, y: -900, width: 440, height: 204), screens: [visible])
        precondition(visible.contains(fitted), "拔掉屏幕后悬浮条必须回到可见区，支持负坐标副屏")
        state.recording = false; state.recordingProfile = .realtime
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!state.miniMode && controller.panel?.isVisible == false, "选回默认实时恢复完整窗口")
        var requestedOpen = false
        state.mainWindow = nil; state.openRecordingWindow = { requestedOpen = true }
        state.showRecordingWindow()
        precondition(requestedOpen, "主窗口已关闭后，mini 展开仍能重建主窗口")
        state.mainWindow = main
        requestedOpen = false
        let delegate = AppDelegate()
        delegate.attach(state)
        state.showMiniRecorder()
        precondition(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) == false,
                     "已恢复主窗口后禁止系统再次创建窗口")
        precondition(state.mainWindow === main && !requestedOpen && main.isVisible,
                     "点击 Dock 应恢复原有主窗口")
        controller.hide(); main.orderOut(nil)
        print("PASS: mini四边及背景拖动命中、控件透传、动态布局、待开始不采集、展开收起不改录音/ASR/计时、菜单栏保会话、异常尺寸、置顶持久化、副屏恢复。无硬件采集。")
    }
}
