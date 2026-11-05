import Foundation
import Combine

struct HotwordDocument: Codable, Equatable { var version: Int; var words: [String] }
struct HotwordReply: Decodable { var status: String; var document: HotwordDocument }
struct HotwordSyncError: LocalizedError { let message: String; var errorDescription: String? { message } }
private final class HotwordNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum HotwordMerge {
    static func key(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    static func merge(base: [String], local: [String], remote: [String]) -> [String] {
        let baseKeys = Set(base.map(key)), localKeys = Set(local.map(key))
        let removed = baseKeys.subtracting(localKeys)
        var result = remote.filter { !removed.contains(key($0)) }
        var present = Set(result.map(key))
        for word in local where !baseKeys.contains(key(word)) && present.insert(key(word)).inserted { result.append(word) }
        return result
    }
}
final class HotwordHTTP {
    private let access: LibrarySyncAccess
    private let session: URLSession
    init(access: LibrarySyncAccess, session: URLSession? = nil) {
        self.access = access
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 25
        self.session = session ?? URLSession(configuration: config, delegate: HotwordNoRedirect(), delegateQueue: nil)
    }
    func request<T: Decodable>(method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let server = access.server
        guard server.scheme == "https" || (server.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(server.host ?? "")), server.user == nil, server.password == nil, server.query == nil, server.fragment == nil else { throw HotwordSyncError(message:"账号服务地址无效。") }
        var request = URLRequest(url: server.appendingPathComponent("v2/hotwords")); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + access.token, forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HotwordSyncError(message:"账号服务响应无效。") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw HotwordSyncError(message:"登录信息无效或已过期，请重新登录。") }
            throw HotwordSyncError(message:"服务请求失败（\(response.statusCode)）。")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
@MainActor final class HotwordSync: ObservableObject {
    @Published private(set) var syncing = false
    @Published private(set) var status = "登录 TalkTuck 后自动同步已确认热词。"
    private let hotwords: PersonalHotwords
    private var access: LibrarySyncAccess?
    private var transport: HotwordHTTP?
    private var epoch = UUID()
    private var poll: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private let automatic: Bool
    private let pollInterval: UInt64
    init(hotwords: PersonalHotwords, automatic: Bool = true, pollInterval: UInt64 = 15_000_000_000) {
        self.hotwords = hotwords; self.automatic = automatic; self.pollInterval = pollInterval
        hotwords.onWordsChanged = { [weak self] in self?.schedule() }
    }
    deinit { poll?.cancel(); debounce?.cancel() }
    func connect(_ value: LibrarySyncAccess?) {
        if let old = access, let value, old.userId == value.userId, old.server == value.server, old.token == value.token { return }
        epoch = UUID(); poll?.cancel(); debounce?.cancel(); poll = nil; debounce = nil; syncing = false
        access = nil; transport = nil
        do {
            try hotwords.activate(account: value?.userId)
            guard let value else { status = "已退出，账号词库保留在本机。"; return }
            access = value; transport = HotwordHTTP(access:value); status = "正在同步个人热词…"
            if automatic { poll = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.synchronize()
                    do { try await Task.sleep(nanoseconds: self?.pollInterval ?? 15_000_000_000) } catch { break }
                }
            } }
        } catch { status = "账号词库无法打开，已暂停同步：\(error.localizedDescription)" }
    }
    private func schedule() {
        guard access != nil, automatic else { return }
        debounce?.cancel(); debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            await self?.synchronize()
        }
    }
    func synchronize() async {
        guard !syncing, let access, let transport else { return }
        let id = epoch; syncing = true; status = "正在同步个人热词…"
        defer { if epoch == id { syncing = false } }
        do {
            var remote: HotwordDocument = try await transport.request()
            for _ in 0..<4 {
                guard epoch == id, self.access?.userId == access.userId else { return }
                let merged = HotwordMerge.merge(base: hotwords.syncBase, local: hotwords.words, remote: remote.words)
                guard merged.count <= 1000 else { throw HotwordSyncError(message:"合并后的词库超过 1000 词，请整理后重试。") }
                try hotwords.applySync(words: merged, version: remote.version, base: remote.words)
                if merged == remote.words { status = "个人热词已同步"; return }
                let submitted = merged
                let reply: HotwordReply = try await transport.request(method:"PUT",body:["baseVersion":remote.version,"words":submitted])
                guard epoch == id, self.access?.userId == access.userId else { return }
                guard ["applied", "conflict"].contains(reply.status) else { throw HotwordSyncError(message:"同步响应无效。") }
                if reply.status == "applied" {
                    let after = HotwordMerge.merge(base: submitted, local: hotwords.words, remote: reply.document.words)
                    try hotwords.applySync(words: after, version: reply.document.version, base: reply.document.words)
                    if after == reply.document.words { status = "个人热词已同步"; return }
                }
                remote = reply.document
            }
            status = "词库同时发生多次修改，将自动重试。"
        } catch { if epoch == id { status = "同步未完成，本机修改已保留：\(error.localizedDescription)" } }
    }
}
