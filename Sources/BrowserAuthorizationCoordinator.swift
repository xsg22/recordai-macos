import AppKit
import Foundation

/// 外部默认浏览器OAuth会话。只接受当前申请的state；重开页面不重新注册或生成申请。
@MainActor
final class BrowserAuthorizationCoordinator {
    private static weak var active: BrowserAuthorizationCoordinator?
    private var continuation: CheckedContinuation<URL, Error>?
    private var deadline: Task<Void, Never>?
    private var authorizationURL: URL?
    private var expectedState: String?
    private let opener: (URL) -> Bool
    var onURLChanged: ((URL?) -> Void)?

    init(opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) { self.opener = opener }

    func authorize(_ url: URL, timeout: TimeInterval = 600) async throws -> URL {
        guard continuation == nil, Self.active == nil else { throw MCPError.message("已有授权页面等待完成，请继续该申请。") }
        guard url.scheme == "https", let host = url.host, !host.isEmpty,
              let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value,
              !state.isEmpty else { throw MCPError.message("授权页面地址无效。") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.authorizationURL = url; self.expectedState = state; Self.active = self
                onURLChanged?(url)
                guard opener(url) else {
                    finish(.failure(MCPError.message("无法打开默认浏览器，请检查系统默认浏览器设置后重试。")))
                    return
                }
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); try Task.checkCancellation() }
                    catch { return }
                    self?.finish(.failure(MCPError.message("等待浏览器授权超时，未发送任何会议内容。请重新连接。")))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func reopen() -> Bool {
        guard continuation != nil, let authorizationURL else { return false }
        return opener(authorizationURL)
    }
    func cancel() { finish(.failure(CancellationError())) }

    @discardableResult static func receive(_ callback: URL) -> Bool {
        guard let active, active.continuation != nil,
              callback.scheme == "coheartranscribe", callback.host == "oauth", callback.path == "/callback",
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == active.expectedState else { return false }
        active.finish(.success(callback))
        return true
    }
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil; authorizationURL = nil; expectedState = nil
        if Self.active === self { Self.active = nil }
        onURLChanged?(nil)
        continuation.resume(with: result)
    }
}
