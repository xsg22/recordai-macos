import AppKit
import SwiftUI

struct QuitConfirmationView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let activity: QuitActivity
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text(activity.title)).font(.system(size: 24, weight: .semibold))
            Text(L10n.text(activity.detail)).font(AppTypography.secondary).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text(activity == .recording ? "返回录音" : "返回应用"), action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                if let action = activity.action { Button(L10n.text(action), action: confirm).buttonStyle(TalkTuckPrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
            }.padding(.top, 8)
        }.padding(28).frame(width: 470).font(AppTypography.body).buttonStyle(TalkTuckSecondaryButtonStyle())
            .background(TalkTuckTheme.surface).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

@MainActor enum QuitConfirmation {
    private static var activeWindow: QuitConfirmationWindow?
    static func present(_ activity: QuitActivity, parent: NSWindow?, completion: @escaping (Bool) -> Void) {
        guard activeWindow == nil else { completion(false); return }
        let panel = QuitConfirmationWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 272), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "TalkTuck"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        activeWindow = panel
        let finish: (Bool) -> Void = { [weak panel] confirmed in
            guard let panel, activeWindow === panel else { return }
            if let parent = panel.sheetParent { parent.endSheet(panel) }
            else { panel.orderOut(nil) }
            activeWindow = nil
            completion(confirmed && activity.action != nil)
        }
        panel.onCancel = { finish(false) }
        let host = NSHostingView(rootView: QuitConfirmationView(activity: activity,
            cancel: { finish(false) }, confirm: { finish(true) }))
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 470, height: max(220, min(520, host.fittingSize.height))))
        if let parent { parent.beginSheet(panel) }
        else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }
}

private final class QuitConfirmationWindow: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }
}
