import AppKit
import Combine
import SwiftUI

/// 一个录音会话、两个显示面。面板不拥有采集器，也不修改 ASR 策略。
@MainActor
final class MiniRecordingController: NSObject, NSWindowDelegate {
    private weak var state: AppState?
    private let defaults: UserDefaults
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private(set) var panel: NSPanel?
    private let positionKey = "miniRecorder.origin.v1"
    private let pinnedKey = "miniRecorder.pinned.v1"
    private(set) var pinned: Bool

    init(state: AppState, defaults: UserDefaults = .standard) {
        self.state = state; self.defaults = defaults
        pinned = defaults.object(forKey: pinnedKey) as? Bool ?? true
        super.init()
        state.miniController = self
        state.$recordingProfile.dropFirst().removeDuplicates().sink { [weak self] profile in
            DispatchQueue.main.async {
                guard let self, let state = self.state, !state.locked else { return }
                if profile == .realtime { state.showRecordingWindow() }
                else { state.showMiniRecorder() }
            }
        }.store(in: &subscriptions)
        state.objectWillChange.sink { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false; self.refresh()
            }
        }.store(in: &subscriptions)
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
    }

    func show() {
        guard let state else { return }
        if panel == nil {
            let panel = MiniRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 76), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "mini 录音条"
            panel.setAccessibilityLabel("mini 录音条")
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: MiniRecordingView(state: state, controller: self))
            self.panel = panel
            let screen = state.mainWindow?.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
            let stored = defaults.array(forKey: positionKey) as? [Double]
            let origin = stored?.count == 2 ? NSPoint(x: stored![0], y: stored![1]) : NSPoint(x: visible.maxX - 684, y: visible.minY + 24)
            panel.setFrame(Self.constrainedFrame(NSRect(origin: origin, size: panel.frame.size), screens: NSScreen.screens.map(\.visibleFrame)), display: false)
        }
        panel?.level = pinned ? .floating : .normal
        NSApp.unhide(nil)
        panel?.orderFrontRegardless()
        refresh()
    }

    func hide() {
        panel?.orderOut(nil)
        state?.setMiniWindowVisible(false)
    }

    func togglePinned() {
        pinned.toggle(); defaults.set(pinned, forKey: pinnedKey)
        panel?.level = pinned ? .floating : .normal
        // pinned 为菜单的呈现状态，同步触发 SwiftUI 重建。
        state?.objectWillChange.send()
    }

    private func refresh() {
        guard let panel, let state else { return }
        let height: CGFloat = state.error != nil || state.recordingIssue != nil ? 168 : 76
        var frame = panel.frame
        frame.origin.y += frame.height - height; frame.size.height = height
        frame = Self.constrainedFrame(frame, screens: NSScreen.screens.map(\.visibleFrame))
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        let visible = panel.isVisible && panel.occlusionState.contains(.visible) && !NSApp.isHidden
        if state.miniWindowVisible != visible { state.setMiniWindowVisible(visible) }
    }

    static func constrainedFrame(_ frame: NSRect, screens: [NSRect]) -> NSRect {
        guard let screen = screens.max(by: { $0.intersection(frame).area < $1.intersection(frame).area }) else { return frame }
        var result = frame
        result.origin.x = min(max(frame.minX, screen.minX + 8), max(screen.minX, screen.maxX - frame.width - 8))
        result.origin.y = min(max(frame.minY, screen.minY + 8), max(screen.minY, screen.maxY - frame.height - 8))
        return result
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        defaults.set([Double(panel.frame.minX), Double(panel.frame.minY)], forKey: positionKey)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        state?.hideMiniToMenuBar(); return false
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private final class MiniRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct MiniRecordingView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @ObservedObject var state: AppState
    let controller: MiniRecordingController
    var inline = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hoveredControl: String?
    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { dark ? Color(red: 0.92, green: 0.94, blue: 0.95) : Color(red: 0.16, green: 0.19, blue: 0.22) }
    private var accent: Color { dark ? Color(red: 0.38, green: 0.65, blue: 1) : RecordAITheme.accent }
    private var surface: Color { RecordAITheme.surface.opacity(0.96) }
    private var mutedInk: Color { ink.opacity(contrast == .increased ? 0.82 : 0.70) }
    private var profile: RecordingProfile { state.locked ? state.activeRecordingProfile : state.recordingProfile }
    private var hasSession: Bool { state.miniSessionID != nil && state.miniSessionID == state.current?.id }
    private var headline: String {
        if state.preparing { return state.recording ? "正在保存录音" : "正在准备录音" }
        if state.recording { return state.paused ? "录音已暂停" : "正在录音" }
        if state.busy {
            switch state.transcriptPhase {
            case .diarizing: return "音频已保存 · 正在区分发言人"
            case .aligning: return "音频已保存 · 正在对齐文字"
            default: return "音频已保存 · 正在转录"
            }
        }
        if state.error != nil { return "需要处理" }
        if hasSession { return state.transcriptPhase == .completed ? "转录已完成" : "录音已保留" }
        return "准备开始录音"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if state.recording {
                    icon("stop.fill", label: "停止并保存") { state.toggleRecording() }
                        .disabled(state.preparing || state.quitting)
                    icon(state.paused ? "play.fill" : "pause.fill", label: state.paused ? (state.canRetryMicrophone ? "重试麦克风并继续录音" : "继续录音") : "暂停录音") { state.pauseRecording() }
                        .disabled(state.preparing || state.quitting || (state.recordingIssue != nil && !state.canRetryMicrophone))
                } else if !state.locked && !hasSession {
                    Button(L10n.text("开始录音")) { state.toggleRecording() }.buttonStyle(RecordAIPrimaryButtonStyle()).disabled(state.syncing)
                } else if state.busy || state.preparing { ProgressView().controlSize(.small) }
                Rectangle().fill(ink.opacity(0.1)).frame(width: 1, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(headline)).font(.system(size: 11, weight: .medium)).foregroundStyle(state.recording && !state.paused ? Color.red : mutedInk)
                    Text(L10n.text(state.recording ? clock(state.elapsed) : hasSession ? "已保存到本机" : "准备就绪"))
                        .font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(ink)
                }.fixedSize().overlay { if !inline { MiniWindowDragRegion() } }.help(L10n.text("拖动此处移动录音条"))
                if state.recording {
                    if reduceMotion { ProgressView(value: state.paused ? 0 : Double(state.level)).tint(accent).frame(width: 130) }
                    else {
                        LiveWaveformView(samples: state.paused ? [Float](repeating: 0, count: 22) : Array(state.liveLevels.suffix(22)), tint: state.paused ? mutedInk : accent)
                            .frame(width: 130, height: 30).accessibilityLabel(L10n.text("录音声波"))
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Label(L10n.text(state.recordingMode.title), systemImage: "mic").lineLimit(1)
                    if let title = state.current?.title { Text(title).lineLimit(1) }
                }.font(.system(size: 11)).foregroundStyle(mutedInk).frame(maxWidth: 150, alignment: .leading)
                    .overlay { if !inline { MiniWindowDragRegion() } }
                icon(inline ? "chevron.up" : "arrow.up.right", label: inline ? "收起为 mini" : "展开录音窗口") {
                    if inline { state.showMiniRecorder() } else { state.showRecordingWindow() }
                }
                Menu { options } label: { Image(systemName: "ellipsis").frame(width: 28, height: 36).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L10n.text("更多录音操作")).accessibilityLabel(L10n.text("更多录音操作"))
            }.frame(height: 48)
            if let issue = state.recordingIssue ?? state.error {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    ScrollView { Text(L10n.text(issue)).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button(L10n.text("查看问题")) { state.showRecordingWindow() }.buttonStyle(RecordAISecondaryButtonStyle())
                    if state.canRetryMicrophone { Button(L10n.text("重试并继续")) { state.pauseRecording() }.buttonStyle(RecordAISecondaryButtonStyle()) }
                }.padding(12).frame(height: 65).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
        }.padding(.horizontal, 18).padding(.vertical, 14)
            .frame(width: 660, height: state.error != nil || state.recordingIssue != nil ? 168 : 76)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(surface)
            }
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ink.opacity(contrast == .increased ? 0.35 : 0.1), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    @ViewBuilder private var options: some View {
        Button(L10n.text("显示完整录音")) { state.showRecordingWindow() }
        if !state.locked {
            Picker(L10n.text("录音模式"), selection: $state.recordingProfile) {
                ForEach(RecordingProfile.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.text("录音音源"), selection: $state.recordingMode) {
                ForEach(MeetingRecordingMode.allCases) { Text($0.title).tag($0) }
            }
            Picker(L10n.text("转写语言"), selection: $state.language) {
                Text(L10n.text("中文")).tag("zh"); Text(L10n.text("中英自动")).tag("auto"); Text(L10n.text("英语")).tag("en")
            }
            if hasSession { Button(L10n.text("开始新录音")) { state.toggleRecording() } }
        }
        Divider()
        Button(L10n.text(controller.pinned ? "取消置顶" : "保持置顶")) { controller.togglePinned() }
        Button(L10n.text("收起到菜单栏（继续运行）")) { state.hideMiniToMenuBar() }
        if state.busy { Button(L10n.text("取消转录，保留音频")) { state.cancel() } }
    }

    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        let primary = symbol == "stop.fill"
        let bare = symbol == "arrow.up.right"
        let hovered = hoveredControl == symbol
        return Button(action: action) {
            Image(systemName: symbol).font(.system(size: primary ? 10 : 13, weight: .medium))
                .foregroundStyle(primary ? Color.white : bare ? mutedInk : ink.opacity(0.85))
                .frame(width: primary ? 42 : 36, height: primary ? 42 : 36)
                .background(primary ? Color(red: 1, green: 0.34, blue: 0.36) : ink.opacity(hovered ? 0.1 : 0.04), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(MiniControlPressStyle()).help(L10n.text(label)).accessibilityLabel(L10n.text(label))
            .onHover { inside in
                if inside { hoveredControl = symbol }
                else if hoveredControl == symbol { hoveredControl = nil }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
    private func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

private struct MiniControlPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? 1 : 0.35)
            .brightness(configuration.isPressed && enabled ? -0.06 : 0)
    }
}

/// 仅覆盖无交互的状态/计时区域。直接把原始鼠标事件交给 AppKit，
/// 避免 SwiftUI HostingView 吞掉背景拖拽，同时不拦截暂停和停止按钮。
private struct MiniWindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) { }
    final class DragView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        private var dragStart: (mouse: NSPoint, origin: NSPoint)?
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let start = dragStart else { return }
            let mouse = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                          y: start.origin.y + mouse.y - start.mouse.y))
        }
        override func mouseUp(with event: NSEvent) { dragStart = nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
