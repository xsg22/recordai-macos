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
            let panel = MiniRecorderPanel(contentRect: NSRect(x: 0, y: 0, width: 525, height: 76), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
            let origin = stored?.count == 2 ? NSPoint(x: stored![0], y: stored![1]) : NSPoint(x: visible.maxX - 549, y: visible.minY + 24)
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
    private var accent: Color { dark ? Color(red: 0.38, green: 0.65, blue: 1) : TalkTuckTheme.accent }
    private var surface: Color { TalkTuckTheme.surface.opacity(0.96) }
    private var mutedInk: Color { ink.opacity(contrast == .increased ? 0.82 : 0.70) }
    private var profile: RecordingProfile { state.locked ? state.activeRecordingProfile : state.recordingProfile }
    private var hasSession: Bool { state.miniSessionID != nil && state.miniSessionID == (state.recording ? state.recordingRecord?.id : state.current?.id) }
    private var headline: String {
        if state.preparing { return state.recording ? "正在保存录音" : "正在准备录音" }
        if state.recording { return state.paused ? "录音已暂停" : state.recordingIsMuted ? "静音录制" : "正在录音" }
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
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(headline)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .foregroundStyle(state.recording && !state.paused && !state.recordingIsMuted ? Color.red : mutedInk)
                    Text(L10n.text(state.recording ? clock(state.elapsed) : hasSession ? "已保存到本机" : "准备就绪"))
                        .font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(ink)
                }.frame(width: 75, alignment: .leading)
                Group {
                    if state.miniShowsCaptions { captions }
                    else if state.recording {
                    if reduceMotion { ProgressView(value: state.paused || state.recordingIsMuted ? 0 : Double(state.level)).tint(accent) }
                    else {
                        LiveWaveformView(samples: state.paused || state.recordingIsMuted ? [Float](repeating: 0, count: 22) : Array(state.liveLevels.suffix(22)), tint: state.paused || state.recordingIsMuted ? mutedInk : accent)
                            .frame(height: 30).accessibilityLabel(L10n.text("录音声波"))
                    }
                    } else { Text(state.current?.title ?? L10n.text("准备开始录音")).font(.system(size: 12)).lineLimit(2) }
                }.frame(width: 180, alignment: .leading)
                Spacer(minLength: 0)
                if state.recording {
                    RecordingSourceToggle(state: state, kind: .microphone, compact: true)
                        .miniWindowControl()
                    RecordingSourceToggle(state: state, kind: .system, compact: true)
                        .miniWindowControl()
                }
                icon("captions.bubble", label: state.miniShowsCaptions ? "切换为声波" : "显示实时字幕") { state.miniShowsCaptions.toggle() }
                if state.recording {
                    icon(state.paused ? "play.fill" : "pause.fill", label: state.paused ? (state.canRetryMicrophone ? "重试麦克风并继续录音" : "继续录音") : "暂停录音") { state.pauseRecording() }
                        .disabled(state.preparing || state.quitting || (state.recordingIssue != nil && !state.canRetryMicrophone))
                    icon("stop.fill", label: "停止并保存") { state.toggleRecording() }
                        .disabled(state.preparing || state.quitting)
                } else if !state.locked && !hasSession {
                    Button(L10n.text("开始录音")) { state.toggleRecording() }.buttonStyle(TalkTuckPrimaryButtonStyle()).disabled(state.syncing)
                        .miniWindowControl()
                } else if state.busy || state.preparing { ProgressView().controlSize(.small) }
                icon(inline ? "arrow.uturn.backward" : "arrow.up.right", label: inline ? "返回正在录音" : "展开录音窗口") {
                    if state.recording { state.returnToRecording() } else { state.showRecordingWindow() }
                }
            }.frame(height: 48)
            if let issue = state.recordingIssue ?? state.error {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    ScrollView { Text(L10n.text(issue)).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button(L10n.text("查看问题")) { state.showRecordingWindow() }.buttonStyle(TalkTuckSecondaryButtonStyle())
                    if state.canRetryMicrophone { Button(L10n.text("重试并继续")) { state.pauseRecording() }.buttonStyle(TalkTuckSecondaryButtonStyle()) }
                }.padding(12).frame(height: 65).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .miniWindowControl()
            }
        }.padding(.horizontal, 14).padding(.vertical, 14)
            .frame(width: 525, height: state.error != nil || state.recordingIssue != nil ? 168 : 76)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(surface)
            }
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ink.opacity(contrast == .increased ? 0.35 : 0.1), lineWidth: 1))
            .overlayPreferenceValue(MiniWindowControlBounds.self) { anchors in
                if !inline {
                    GeometryReader { geometry in
                        MiniWindowDragRegion(excludedRects: anchors.map { geometry[$0] })
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .contextMenu { options }
    }
    private var captions: some View {
        let preview = state.miniTranscriptPreview
        return VStack(alignment: .leading, spacing: 3) {
            if !preview.confirmed.isEmpty { Text(preview.confirmed).foregroundStyle(ink) }
            if !preview.partial.isEmpty { Text(preview.partial).foregroundStyle(mutedInk) }
            else if preview.confirmed.isEmpty {
                Text(L10n.text(!state.liveEnabled ? "仅录音 · 停止后转录" : state.liveStatus.isEmpty ? "等待语音…" : state.liveStatus)).foregroundStyle(mutedInk)
            }
        }.font(.system(size: 12)).lineLimit(1).truncationMode(.head)
            .opacity(state.paused || state.recordingIsMuted ? 0.65 : 1)
            .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("实时转录预览"))
    }
    @ViewBuilder private var options: some View {
        Button(L10n.text("显示完整录音")) { if state.recording { state.returnToRecording() } else { state.showRecordingWindow() } }
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
                .foregroundStyle(primary ? accent : bare ? mutedInk : ink.opacity(0.85))
                .frame(width: 30, height: 32)
                .background(primary || (symbol == "captions.bubble" && state.miniShowsCaptions) ? accent.opacity(0.12) : ink.opacity(hovered ? 0.1 : 0.02), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(MiniControlPressStyle()).help(L10n.text(label)).accessibilityLabel(L10n.text(label))
            .onHover { inside in
                if inside { hoveredControl = symbol }
                else if hoveredControl == symbol { hoveredControl = nil }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .miniWindowControl()
    }
    private func clock(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MiniControlPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? 1 : 0.35)
            .brightness(configuration.isPressed && enabled ? -0.06 : 0)
    }
}

private struct MiniWindowControlBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func miniWindowControl() -> some View {
        anchorPreference(key: MiniWindowControlBounds.self, value: .bounds) { [$0] }
    }
}

/// 覆盖整个面板的空白、状态与声波，交互控件的实际布局范围透传鼠标事件。
/// SwiftUI 的 inline 录音条不安装此覆盖层，不能拖动主窗口。
private struct MiniWindowDragRegion: NSViewRepresentable {
    var excludedRects: [CGRect]
    func makeNSView(context: Context) -> MiniWindowDragView { MiniWindowDragView() }
    func updateNSView(_ nsView: MiniWindowDragView, context: Context) {
        nsView.excludedRects = excludedRects
    }
}

final class MiniWindowDragView: NSView {
    var excludedRects: [CGRect] = [] {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !excludedRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }
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
    override func resetCursorRects() {
        // 光标也避开按钮，不能把控件显示成可拖动区域。
        var regions = [bounds]
        for excluded in excludedRects {
            regions = regions.flatMap { region -> [CGRect] in
                let cut = region.intersection(excluded)
                guard !cut.isNull, !cut.isEmpty else { return [region] }
                return [CGRect(x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
                        CGRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY),
                        CGRect(x: region.minX, y: cut.minY, width: cut.minX - region.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: region.maxX - cut.maxX, height: cut.height)]
                    .filter { !$0.isEmpty }
            }
        }
        for region in regions { addCursorRect(region, cursor: .openHand) }
    }
}
