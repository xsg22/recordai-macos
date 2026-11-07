import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OSLog

struct FeedbackMailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeLogs = true
    @State private var images: [URL] = []
    @State private var error: String?
    @State private var sharingService: NSSharingService?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("意见反馈")).font(.system(size: 22, weight: .semibold))
            Text(L10n.text("问题描述")).font(.headline)
            TextEditor(text: $message).font(.body).frame(height: 120).border(Color.secondary.opacity(0.25)).accessibilityIdentifier("feedback-description")
            HStack {
                Button(L10n.text("选择图片")) { selectImages() }
                Text(L10n.format("已选择 {0} 张图片", String(images.count))).foregroundStyle(.secondary)
                if !images.isEmpty { Button(L10n.text("清除")) { images = [] } }
            }
            Toggle(L10n.text("附带客户端日志"), isOn: $includeLogs).toggleStyle(.checkbox)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L10n.text("关闭")) { dismiss() }
                Spacer()
                Button(L10n.text("打开邮件")) { openMail() }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540).accessibilityIdentifier("feedback-form")
    }
    private func selectImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { images = panel.urls }
    }
    private func openMail() {
        do {
            guard images.count <= 3 else { error = L10n.text("最多选择 3 张图片。"); return }
            for image in images {
                guard let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000 else { error = L10n.text("每张图片不能超过 8 MB。"); return }
            }
            var items: [Any] = [message]
            items.append(contentsOf: images)
            if includeLogs {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let position = store.position(date: Date().addingTimeInterval(-24 * 3600))
                let entries = try store.getEntries(at: position).compactMap { $0 as? OSLogEntryLog }
                let lines = entries.map { "\($0.date) [\($0.subsystem)] [\($0.category)] [\(String(describing: $0.level))] \($0.composedMessage)" }
                let header = "TalkTuck macOS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · \(ProcessInfo.processInfo.operatingSystemVersionString)\nScope: readable current-process unified logs from the last 24 hours; earlier processes and worker-process logs are not included. Persistent events are in the accompanying JSONL file.\n"
                let data = Data((header + (lines.isEmpty ? "No application log entries available.\n" : lines.joined(separator: "\n"))).utf8)
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("talktuck-feedback-\(UUID().uuidString).log")
                try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen]); items.append(file)
                let eventsFile = FileManager.default.temporaryDirectory.appendingPathComponent("talktuck-events-\(UUID().uuidString).jsonl")
                try FeedbackDiagnostics.shared.snapshot().write(to: eventsFile, options: [.atomic, .completeFileProtectionUnlessOpen]); items.append(eventsFile)
            }
            guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) else {
                error = L10n.text("无法打开邮件，请配置邮件应用后重试；反馈内容仍会保留。收件人：xsgnzb1@gmail.com")
                return
            }
            service.recipients = ["xsgnzb1@gmail.com"]; service.subject = L10n.text("TalkTuck 意见反馈 (Mac)")
            sharingService = service; error = nil; service.perform(withItems: items)
        } catch { self.error = L10n.text("图片或客户端日志准备失败，请重试，或取消勾选日志后发送。") }
    }
}
