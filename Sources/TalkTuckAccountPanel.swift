import SwiftUI

struct TalkTuckAccountPanel: View {
    @ObservedObject var store: TalkTuckAccountStore
    @State private var phone = ""
    @State private var code = ""
    @State private var agreed = false
    @State private var resendAt = Date.distantPast
    var body: some View {
        RecordAICard {
            Label("TalkTuck", systemImage: "person.crop.circle").font(AppTypography.heading)
            if store.isSignedIn {
                Text(L10n.text("已登录") + (store.displayName.isEmpty ? "" : " · " + store.displayName))
                Text(L10n.text(store.librarySyncAvailable ? "登录成功后，可单独开启文字与分组同步。" : "跨设备同步正在准备中，录音继续保存在本机。"))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
                Button(L10n.text("退出登录")) { store.signOut(); phone = ""; code = "" }
            } else {
                Text(L10n.text("使用与 iPhone 相同的手机号登录。登录不会自动上传录音。"))
                    .font(AppTypography.secondary).foregroundStyle(.secondary)
                TextField(L10n.text("手机号"), text: $phone).textContentType(.telephoneNumber)
                HStack {
                    TextField(L10n.text("6 位验证码"), text: $code).textContentType(.oneTimeCode)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Button(L10n.text(context.date < resendAt ? "稍后重发" : "获取验证码")) {
                            Task { if await store.sendSMS(phone: phone) { resendAt = Date().addingTimeInterval(60) } }
                        }.disabled(store.busy || !agreed || phone.count != 11 || context.date < resendAt)
                    }
                }
                Toggle(L10n.text("我已阅读隐私政策并同意发送登录验证码"), isOn: $agreed)
                HStack {
                    Link(L10n.text("隐私政策"), destination: URL(string: "https://xueshengguo.com/apps/talktuck/privacy/")!)
                }.font(AppTypography.secondary)
                Button(L10n.text("登录")) {
                    Task { if await store.signInSMS(phone: phone, code: code) { phone = ""; code = "" } }
                }.disabled(store.busy || !agreed || phone.count != 11 || code.count != 6)
            }
            if store.busy { ProgressView().controlSize(.small) }
            if let message = store.message { Text(L10n.text(message)).font(AppTypography.secondary).foregroundStyle(.secondary) }
        }.textFieldStyle(.roundedBorder).task { await store.restore() }
    }
}
