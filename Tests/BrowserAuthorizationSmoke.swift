import Foundation
@main struct BrowserAuthorizationSmoke {
    @MainActor static func main() async throws {
        var opened: [URL] = []
        let flow = BrowserAuthorizationCoordinator(opener: { opened.append($0); return true })
        let url = URL(string: "https://auth.example.test/authorize?state=test-state&code_challenge=test")!
        let pending = Task { try await flow.authorize(url) }
        await Task.yield()
        precondition(opened.count == 1)
        precondition(flow.reopen() && opened.count == 2 && opened[0] == opened[1])
        precondition(!BrowserAuthorizationCoordinator.receive(URL(string: "coheartranscribe://oauth/callback?state=wrong&code=x")!))
        let callback = URL(string: "coheartranscribe://oauth/callback?state=test-state&code=ok")!
        precondition(BrowserAuthorizationCoordinator.receive(callback))
        let result = try await pending.value
        precondition(result == callback && !flow.reopen())
        precondition(!BrowserAuthorizationCoordinator.receive(callback))
        let cancel = Task { try await flow.authorize(url) }
        await Task.yield(); flow.cancel()
        do { _ = try await cancel.value; fatalError("取消必须结束等待") } catch is CancellationError { }
        let fail = BrowserAuthorizationCoordinator(opener: { _ in false })
        do { _ = try await fail.authorize(url); fatalError("打开失败必须返回错误") } catch is MCPError { }
        let timeout = Task { try await flow.authorize(url, timeout: 0.02) }
        do { _ = try await timeout.value; fatalError("超时必须结束等待") } catch is MCPError { }
        print("PASS: 默认浏览器打开、同链接重开、state与回调校验、重复回调拒绝、取消/超时/打开失败收口。没有打开真实页面。")
    }
}
