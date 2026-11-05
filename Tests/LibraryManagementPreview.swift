import SwiftUI

/// 本地验收专用入口；显式隔离资料目录，绝不加载或改写个人库。
@main struct LibraryManagementPreview: App {
    @ObservedObject private var appLanguage = AppLanguage.shared
    @StateObject private var state: AppState
    init() {
        let args = CommandLine.arguments
        let path: String
        if let flag = args.firstIndex(of: "--library-root"), args.indices.contains(flag + 1) { path = args[flag + 1] }
        else if let url = Bundle.main.url(forResource: "LibraryPreviewRoot", withExtension: "txt"), let value = try? String(contentsOf: url, encoding: .utf8) { path = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { fatalError("需要隔离验收目录") }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.lastPathComponent == "LibraryData", FileManager.default.fileExists(atPath: root.appendingPathComponent(".talktuck-isolated-test").path) else { fatalError("不能使用非验收目录") }
        let next = AppState(storageURL: root, connectionNamespace: "library-preview-" + root.deletingLastPathComponent().lastPathComponent)
        if let first = next.history.first { next.select(first.id) }
        _state = StateObject(wrappedValue: next)
    }
    var body: some Scene {
        WindowGroup {
            MainView(state: state).frame(minWidth: 1040, minHeight: 760)
                .environment(\.locale, appLanguage.locale)
                .background(RecordingWindowObserver(state: state).frame(width: 0, height: 0))
                .font(AppTypography.body).controlSize(.extraLarge)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }.defaultSize(width: 1440, height: 900)
        Settings { RecordingAppConfigurationView(state: state).environment(\.locale, appLanguage.locale) }
    }
}
