import SwiftUI

struct TalkTuckErrorView: View {
    @ObservedObject private var appLanguage = AppLanguage.shared
    let message: String
    let close: () -> Void
    var retry: (() -> Void)? = nil
    private var recordingSaved:Bool { message.hasPrefix("录音已停止并保存。") }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.text(recordingSaved ? "录音已保存" : "操作未能完成")).font(.system(size: 24, weight: .semibold))
            Text(L10n.text(message)).font(AppTypography.secondary).foregroundStyle(TalkTuckTheme.muted)
                .lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(L10n.text(recordingSaved ? "知道了" : "返回"), action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if let retry { Button(L10n.text("重试"), action: retry).buttonStyle(TalkTuckPrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
            }
        }.padding(28).frame(width: 470).font(AppTypography.body).buttonStyle(TalkTuckSecondaryButtonStyle())
    }
}
