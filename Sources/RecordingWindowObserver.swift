import AppKit
import SwiftUI

/// 仅观察实际主窗口可见性；遮挡/最小化不触碰采集或推理会话。
struct RecordingWindowObserver: NSViewRepresentable {
    let state: AppState
    func makeNSView(context: Context) -> WindowProbe { WindowProbe(state: state) }
    func updateNSView(_ nsView: WindowProbe, context: Context) { }
    final class WindowProbe: NSView {
        weak var state: AppState?
        private var observations: [NSObjectProtocol] = []
        init(state: AppState) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach { NotificationCenter.default.removeObserver($0) }; observations = []
            guard let window else { return }
            state?.mainWindow = window
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                let isApplication = name == NSApplication.didHideNotification || name == NSApplication.didUnhideNotification
                observations.append(NotificationCenter.default.addObserver(forName: name, object: isApplication ? nil : window, queue: .main) { [weak self, weak window] notification in
                    let name = notification.name
                    Task { @MainActor [weak self, weak window] in
                        guard let self, let window, self.state?.mainWindow === window else { return }
                        if name == NSWindow.didBecomeKeyNotification { self.state?.restoreMainPresentation() }
                        if name == NSWindow.willCloseNotification { self.state?.mainWindowVisible = false; self.state?.mainWindow = nil }
                        else { self.refresh() }
                    }
                })
            }
            refresh()
        }
        private func refresh() {
            guard let window else { return }
            let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) && !NSApp.isHidden
            if state?.mainWindowVisible != visible { state?.mainWindowVisible = visible }
        }
        deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

struct RecordingMenuBarView: View {
    @ObservedObject var state: AppState
    var body: some View {
        Text(state.recording ? (state.paused ? "录音已暂停" : "正在录音") : state.preparing ? "正在准备或保存录音" : "正在处理转录任务").font(.headline)
        if state.recording {
            Text(state.activeRecordingProfile.title)
            Text("已录制 \(state.elapsed / 60) 分 \(state.elapsed % 60) 秒")
        }
        if let issue = state.recordingIssue { Text(issue) }
        Divider()
        Button("打开录音窗口") { state.showRecordingWindow() }
        Button("显示 mini 录音条") { state.showMiniRecorder() }
        if !state.locked && state.miniMode { Button("开始新录音") { state.toggleRecording() } }
        if state.recording {
            Button(state.paused ? (state.canRetryMicrophone ? "重试并继续" : "继续录音") : "暂停录音") { state.pauseRecording() }
                .disabled(state.preparing || (state.recordingIssue != nil && !state.canRetryMicrophone))
            Button("停止并保存") { state.toggleRecording() }.disabled(state.preparing)
        } else if state.busy {
            Button("取消转录，保留音频") { state.cancel() }
        }
    }
}
