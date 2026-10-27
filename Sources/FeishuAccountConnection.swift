import AppKit
import Foundation
import SwiftUI

/// 官方 CLI 管理自己的钥匙串凭据，客户端不读取或存储 App Secret / 用户 token。
@MainActor
final class FeishuAccountConnection: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var status = "连接飞书后，可保存到个人云文档"
    @Published private(set) var accountDisplay = ""
    @Published var error: String?
    private let executable: URL?
    private let profile = "cohear-meetings"
    private var identity: String?
    private let pendingAccount: String
    @Published private(set) var hasPendingAuthorization = false

    init(executable: URL? = Bundle.main.url(forResource: "lark-cli", withExtension: nil, subdirectory: "Integrations"), pendingAccount: String = "feishu-device-authorization.cohear-meetings") {
        self.executable = executable
        self.pendingAccount = pendingAccount
        hasPendingAuthorization = false // connect时查询待处理授权，不在App启动时阻塞钥匙串。
    }

    func restore() async {
        guard !busy else { return }
        await checkAuthorization()
    }

    /// 只读状态，不发起授权、不打开浏览器，也不把查询错误当作“未配置”。
    func checkAuthorization() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await queryStatus()
            if connected { clearPending() }
            else { status = hasPendingAuthorization ? "已有授权申请，请完成浏览器授权后继续检查" : "尚未完成个人授权，可连接飞书" }
        } catch AccountCommandFailure.notConfigured {
            connected = false; status = "尚未连接飞书，可点击连接开始官方引导"
        } catch {
            status = "授权状态查询暂未完成；没有发起新申请，请稍后再检查"
        }
    }

    private func queryStatus() async throws -> Bool {
        guard let executable else { throw MCPError.message("安装包缺少飞书连接组件。") }
        let result = try await AccountCommandRunner.run(executable: executable,
            arguments: ["--profile", profile, "auth", "status", "--json"], timeout: 30)
        applyStatus(result)
        return (FeishuJSON.body(result)["appId"] as? String)?.isEmpty == false
    }

    /// 优先采用已有授权，然后继续同一次device flow；只有明确未配置才初始化应用。
    func connect() async {
        guard !busy else { return }
        guard let executable else { error = "安装包缺少飞书连接组件，请安装完整版本。"; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let hasApp: Bool
            do { hasApp = try await queryStatus() }
            catch AccountCommandFailure.notConfigured { hasApp = false }
            // 网络/CLI错误直接退出，不能推断为无应用并创建新申请。
            if connected { clearPending(); return }
            if !hasApp {
                status = "第 1 步：请在浏览器完成飞书应用授权；组织可能要求管理员批准"
                try await FeishuBrowserSetup.run(executable: executable,
                    arguments: ["config", "init", "--new", "--brand", "feishu", "--lang", "zh", "--name", profile])
                _ = try await queryStatus()
                if connected { clearPending(); return }
            }
            if let pending = try MCPKeychain.read(account: pendingAccount) {
                guard pending.expiresAt.map({ $0 > Date() }) ?? false else {
                    status = "上次申请已过期；需要重新授权时请明确点击重新申请"
                    error = "上次授权申请已过期。先检查已有授权；若仍未授权，再选择重新申请。"
                    return
                }
                hasPendingAuthorization = true
                status = "正在继续获取上一次授权结果，不会创建新申请…"
                try await poll(code: pending.accessToken, executable: executable)
                return
            }
            status = "第 2 步：请在浏览器授权个人云文档访问"
            let started = try await AccountCommandRunner.run(executable: executable,
                arguments: ["--profile", profile, "auth", "login", "--domain", "docs", "--no-wait", "--json"])
            let authorization = try FeishuJSON.authorization(started)
            let expires = FeishuJSON.body(started)["expires_in"] as? Double ?? 600
            try MCPKeychain.save(MCPCredential(accessToken: authorization.code,
                expiresAt: Date().addingTimeInterval(expires)), account: pendingAccount)
            hasPendingAuthorization = true
            guard NSWorkspace.shared.open(authorization.url) else { throw MCPError.message("无法打开浏览器。申请已保存，可继续检查。") }
            try await poll(code: authorization.code, executable: executable)
        } catch {
            // 命令超时之后仍可能已落盘，先检查状态，不要求用户重复授权。
            if (try? await queryStatus()) != nil, connected { clearPending(); return }
            self.error = "授权结果暂未确认。请先点“检查授权状态”；已有申请会保留，不会自动创建新申请。"
            status = "等待确认已有授权，会议仍保存在本机"
        }
    }

    private func poll(code: String, executable: URL) async throws {
        _ = try await AccountCommandRunner.run(executable: executable,
            arguments: ["--profile", profile, "auth", "login", "--device-code", code, "--json"], timeout: 660)
        _ = try await queryStatus()
        guard connected else { throw MCPError.message("授权结果暂未确认。") }
        clearPending()
    }

    /// 只有用户明确要求重新申请才删除待处理code；有效身份仍优先复用。
    func requestNewAuthorization() async {
        guard !busy else { return }
        await checkAuthorization()
        if connected { return }
        clearPending()
        await connect()
    }
    private func clearPending() {
        do { try MCPKeychain.delete(account: pendingAccount); hasPendingAuthorization = false }
        catch { /* 旧code仍留在钥匙串，已有有效身份优先使用，不会重复申请。 */ }
    }

    func sync(title: String, text: String) async throws -> MCPSyncReceipt {
        guard !busy, connected, let executable, let identity else { throw MCPError.message("请先连接飞书个人账号。") }
        busy = true; error = nil
        defer { busy = false }
        let before = try await AccountCommandRunner.run(executable: executable,
            arguments: ["--profile", profile, "auth", "status", "--json"])
        guard FeishuJSON.identity(before) == identity else {
            connected = false
            throw MCPError.message("飞书账号发生变化，请重新连接确认后再同步。")
        }
        status = "正在保存到个人飞书文档"
        let created = try await AccountCommandRunner.run(executable: executable,
            arguments: ["--profile", profile, "docs", "+create", "--as", "user", "--doc-format", "markdown",
                        "--title", title, "--parent-position", "my_library", "--content", "-", "--format", "json"],
            input: Data(text.utf8))
        let document = try FeishuJSON.createdDocument(created)
        do {
            let fetched = try await AccountCommandRunner.run(executable: executable,
                arguments: ["--profile", profile, "docs", "+fetch", "--as", "user", "--doc", document.id,
                            "--doc-format", "markdown", "--format", "json"])
            guard let content = FeishuJSON.fetchedContent(fetched),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.message("未返回文档内容")
            }
            let expected = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard expected.isEmpty || content.contains(expected) else {
                throw MCPError.message("回读内容与本次同步正文尚未确认一致")
            }
            status = "已保存到飞书，并确认文档可读取"
            return MCPSyncReceipt(tool: "lark-cli docs +create/+fetch", result: "个人文档已创建并回读验证。", remoteURL: document.url)
        } catch {
            status = "文档已创建，回读暂未完成"
            // 返回真实创建结果，避免用户重试造成重复文档，明确不假称完整验收。
            return MCPSyncReceipt(tool: "lark-cli docs +create", result: "文档已创建，但暂未完成回读验证，请打开文档确认，勿重复同步。", remoteURL: document.url)
        }
    }

    private func applyStatus(_ result: [String: Any]) {
        identity = FeishuJSON.identity(result)
        connected = identity != nil
        let body = FeishuJSON.body(result)
        let identities = body["identities"] as? [String: Any]
        let user = identities?["user"] as? [String: Any]
        accountDisplay = user?["userName"] as? String ?? "飞书个人账号"
        status = connected ? "已连接 \(accountDisplay) · 保存到个人云文档" : "尚未授权个人云文档访问"
    }
}

/// auth/config 输出是裸 JSON；业务命令则采用 {ok, identity, data} envelope。
enum FeishuJSON {
    static func body(_ json: [String: Any]) -> [String: Any] { json["data"] as? [String: Any] ?? json }
    static func identity(_ json: [String: Any]) -> String? {
        let value = body(json)
        guard let app = value["appId"] as? String, !app.isEmpty,
              let identities = value["identities"] as? [String: Any],
              let user = identities["user"] as? [String: Any],
              user["available"] as? Bool == true,
              let open = user["openId"] as? String, !open.isEmpty else { return nil }
        return app + ":" + open
    }
    static func authorization(_ json: [String: Any]) throws -> (url: URL, code: String) {
        let value = body(json)
        guard let raw = value["verification_url"] as? String, let url = officialURL(raw),
              let code = value["device_code"] as? String, !code.isEmpty else {
            throw MCPError.message("飞书授权响应无效。")
        }
        return (url, code)
    }
    static func officialURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host,
              host == "feishu.cn" || host.hasSuffix(".feishu.cn") || host == "larksuite.com" || host.hasSuffix(".larksuite.com") else { return nil }
        return url
    }
    static func createdDocument(_ json: [String: Any]) throws -> (id: String, url: URL?) {
        guard json["ok"] as? Bool == true, json["identity"] as? String == "user",
              let document = body(json)["document"] as? [String: Any],
              let id = document["document_id"] as? String, !id.isEmpty else {
            throw MCPError.message("飞书未确认个人文档已创建。")
        }
        return (id, (document["url"] as? String).flatMap(officialURL))
    }
    static func fetchedContent(_ json: [String: Any]) -> String? {
        guard json["ok"] as? Bool == true, json["identity"] as? String == "user",
              let document = body(json)["document"] as? [String: Any] else { return nil }
        return document["content"] as? String
    }
}

/// config init 尚无 JSON no-wait 模式：实时从 stderr 提取官方授权 URL，避免等待结束才显示链接。
private enum FeishuBrowserSetup {
    static func run(executable: URL, arguments: [String]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            let collector = FeishuURLCollector()
            errors.fileHandleForReading.readabilityHandler = { handle in
                if let url = collector.consume(handle.availableData) {
                    DispatchQueue.main.async { _ = NSWorkspace.shared.open(url) }
                }
            }
            defer { errors.fileHandleForReading.readabilityHandler = nil }
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = Date().addingTimeInterval(600)
            while process.isRunning {
                if Task.isCancelled || Date() > deadline {
                    process.terminate()
                    throw MCPError.message("飞书浏览器授权已超时，请重试。")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard process.terminationStatus == 0 else { throw MCPError.message("飞书应用授权未完成。") }
        }.value
    }
}

/// Handler 可能跨线程调用，用锁保护有限缓冲；从不输出原始 stderr。
private final class FeishuURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var opened = false
    func consume(_ chunk: Data) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard !chunk.isEmpty, !opened else { return nil }
        buffer.append(chunk)
        if buffer.count > 65536 { buffer = Data(buffer.suffix(65536)) }
        let content = String(decoding: buffer, as: UTF8.self)
        // 要求 URL 后跟空白，避免 stderr 分段时打开被截断的授权链接。
        let expression = try? NSRegularExpression(pattern: "https://[^\\s\\u001B]+(?=\\s)")
        let matches = expression?.matches(in: content, range: NSRange(content.startIndex..., in: content)) ?? []
        for match in matches {
            if let range = Range(match.range, in: content), let url = FeishuJSON.officialURL(String(content[range])) {
                opened = true
                return url
            }
        }
        return nil
    }
}
