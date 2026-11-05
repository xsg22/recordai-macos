import Foundation
import Combine
import Security

struct TalkTuckSession: Codable {
    var server: String
    var token: String
    var userId: UUID
    var loginSubject: String
    var expiresAt: Date
    var displayName: String
    var librarySyncAvailable: Bool? = nil
}

@MainActor protocol TalkTuckSessionStorage {
    func read() throws -> TalkTuckSession?
    func write(_ session: TalkTuckSession?) throws
}

@MainActor struct TalkTuckKeychain: TalkTuckSessionStorage {
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.xsg.talktuck.account", kSecAttrAccount as String: "session.v2"]
    func read() throws -> TalkTuckSession? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TalkTuckAccountError.keychain }
        return try JSONDecoder().decode(TalkTuckSession.self, from: data)
    }
    func write(_ session: TalkTuckSession?) throws {
        guard let session else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw TalkTuckAccountError.keychain }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw TalkTuckAccountError.keychain }
        } else if status != errSecSuccess { throw TalkTuckAccountError.keychain }
    }
}

private final class TalkTuckNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum TalkTuckAccountError: Error, Equatable {
    case unauthorized, unavailable, invalidReply, keychain, invalidCode, rateLimited
    var message: String {
        switch self {
        case .unauthorized: return "登录信息无效或已过期，请重新登录。"
        case .keychain: return "无法访问系统钥匙串，请重试。"
        case .invalidReply: return "账号服务尚未就绪，请稍后重试。"
        case .unavailable: return "无法连接账号服务，请检查网络后重试。"
        case .invalidCode: return "验证码无效或已过期，请重新获取。"
        case .rateLimited: return "请求过于频繁，请稍后重试。"
        }
    }
}

/// Account access only. No reference to the library, recordings, ASR, or upload APIs.
@MainActor final class TalkTuckAccountStore: ObservableObject {
    @Published private(set) var userId: UUID?
    @Published private(set) var displayName = ""
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    var onSessionChange: (() -> Void)?
    @Published private(set) var librarySyncAvailable = false
    var syncAccess: LibrarySyncAccess? { guard let active else { return nil };return LibrarySyncAccess(server:baseURL,token:active.token,userId:active.userId) }
    var isSignedIn: Bool { userId != nil }
    private let baseURL: URL
    private let session: URLSession
    private let credentials: TalkTuckSessionStorage
    private var generation = UUID()
    private var didRestore = false
    private var active: TalkTuckSession?
    private let deviceId: String
    private struct Login: Decodable { let token: String; let expiresIn: Int; let userId: UUID; let loginSubject: String; let username: String? }
    private struct EmptyResponse: Decodable {}
    private struct Identity: Decodable { let userId: UUID; let schemaVersion: Int; let librarySync: Bool; let audioSync: Bool }

    init(baseURL: URL = URL(string: "https://xueshengguo.com/recordai")!, session: URLSession? = nil,
         credentials: TalkTuckSessionStorage? = nil, deviceId: UUID? = nil) {
        self.baseURL = baseURL
        if let deviceId { self.deviceId = deviceId.uuidString.lowercased() }
        else {
            let key = "TalkTuck.accountDeviceId.v1"
            let id = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
            self.deviceId = id.uuidString.lowercased(); UserDefaults.standard.set(self.deviceId, forKey: key)
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 20
        self.session = session ?? URLSession(configuration: config, delegate: TalkTuckNoRedirect(), delegateQueue: nil)
        self.credentials = credentials ?? TalkTuckKeychain()
    }

    func restore() async {
        guard !didRestore, !busy else { return }; didRestore = true
        let epoch = generation
        busy = true; defer { if generation == epoch { busy = false } }
        do {
            guard let saved = try credentials.read(), saved.server == baseURL.absoluteString else { return }
            guard saved.expiresAt > Date() else { throw TalkTuckAccountError.unauthorized }
            if saved.librarySyncAvailable == true {
                active = saved; userId = saved.userId; displayName = saved.displayName; librarySyncAvailable = true; onSessionChange?()
            }
            let identity: Identity = try await request("v2/me", token: saved.token)
            guard generation == epoch else { return }
            guard identity.schemaVersion == 1, identity.userId == saved.userId else { throw TalkTuckAccountError.invalidReply }
            active = saved; userId = saved.userId; displayName = saved.displayName; message = nil; librarySyncAvailable = identity.librarySync; onSessionChange?()
        } catch {
            guard generation == epoch else { return }
            if active != nil && ((error is URLError) || (error as? TalkTuckAccountError) == .unavailable) {
                message = "离线账号已打开，联网后会验证并同步。"
            } else {
                active = nil; userId = nil; displayName = ""; librarySyncAvailable = false; onSessionChange?()
                message = Self.safeMessage(error)
            }
        }
    }

    func sendSMS(phone: String) async -> Bool {
        guard !busy, phone.range(of: #"^1[3-9]\d{9}$"#, options: .regularExpression) != nil else { return false }
        busy = true; let epoch = generation; defer { if generation == epoch { busy = false } }
        do {
            let _: EmptyResponse = try await request("v1/auth/sms/send", body: ["phone": phone, "deviceId": deviceId])
            guard generation == epoch else { return false }
            message = "验证码已发送，请留意短信。"; return true
        } catch { if generation == epoch { message = Self.safeMessage(error) }; return false }
    }

    func signInSMS(phone: String, code: String) async -> Bool {
        guard phone.range(of: #"^1[3-9]\d{9}$"#, options: .regularExpression) != nil,
              code.range(of: #"^\d{6}$"#, options: .regularExpression) != nil else { return false }
        return await signIn("v1/auth/sms/login", body: ["phone": phone, "code": code])
    }

    // Used by local integration validation and existing password accounts; not a main UI flow.
    func signInPassword(username: String, password: String) async -> Bool {
        await signIn("v1/auth/account", body: ["username": username, "password": password])
    }

    private func signIn(_ path: String, body: [String: String]) async -> Bool {
        guard !busy else { return false }
        generation = UUID(); let epoch = generation; busy = true; message = nil
        defer { if generation == epoch { busy = false } }
        do {
            let result: Login = try await request(path, body: body)
            guard generation == epoch else { return false }
            let identity: Identity = try await request("v2/me", token: result.token)
            guard generation == epoch else { return false }
            guard identity.schemaVersion == 1, result.userId == identity.userId, !result.loginSubject.isEmpty, !result.token.isEmpty, result.expiresIn > 0 else { throw TalkTuckAccountError.invalidReply }
            let saved = TalkTuckSession(server: baseURL.absoluteString, token: result.token, userId: identity.userId, loginSubject: result.loginSubject,
                expiresAt: Date().addingTimeInterval(Double(result.expiresIn)), displayName: result.username ?? "", librarySyncAvailable: identity.librarySync)
            try credentials.write(saved)
            active = saved; userId = saved.userId; displayName = saved.displayName; librarySyncAvailable = identity.librarySync; onSessionChange?()
            return true
        } catch { if generation == epoch { message = Self.safeMessage(error) }; return false }
    }

    func signOut() {
        generation = UUID(); busy = false
        do {
            try credentials.write(nil)
            active = nil; userId = nil; displayName = ""; message = nil; librarySyncAvailable = false; onSessionChange?()
        } catch { message = Self.safeMessage(error) }
    }

    private func request<T: Decodable>(_ path: String, body: [String: String]? = nil, token: String? = nil) async throws -> T {
        guard baseURL.scheme == "https" || (baseURL.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(baseURL.host ?? "")),
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw TalkTuckAccountError.invalidReply }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TalkTuckAccountError.invalidReply }
        if http.statusCode == 401 { throw path == "v1/auth/sms/login" ? TalkTuckAccountError.invalidCode : TalkTuckAccountError.unauthorized }
        if http.statusCode == 403 { throw TalkTuckAccountError.unauthorized }
        if (300..<500).contains(http.statusCode) && http.statusCode != 429 { throw TalkTuckAccountError.invalidReply }
        if http.statusCode == 429 { throw TalkTuckAccountError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw TalkTuckAccountError.unavailable }
        return try JSONDecoder().decode(T.self, from: http.statusCode == 204 ? Data("{}".utf8) : data)
    }

    private static func safeMessage(_ error: Error) -> String {
        (error as? TalkTuckAccountError ?? .unavailable).message
    }
}
