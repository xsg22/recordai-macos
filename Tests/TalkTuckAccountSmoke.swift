import Foundation

@MainActor private final class MemorySession: TalkTuckSessionStorage {
    var saved: TalkTuckSession?
    func read() throws -> TalkTuckSession? { saved }
    func write(_ session: TalkTuckSession?) throws { saved = session }
}

private final class OfflineAccountProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private final class NetworkDeniedAccountProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self,didFailWithError:NSError(domain:NSPOSIXErrorDomain,code:Int(EPERM))) }
    override func stopLoading() {}
}
private final class DelayedLogin: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"token\":\"synthetic-only\",\"expiresIn\":3600}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main struct TalkTuckAccountSmoke {
    @MainActor static func main() async throws {
        let url = URL(string: CommandLine.arguments[1])!
        let secrets = MemorySession()
        let store = TalkTuckAccountStore(baseURL: url, credentials: secrets, deviceId: UUID())
        let sent = await store.sendSMS(phone: "13800000000") // Fixture never sends a real SMS.
        precondition(sent, "204 SMS success must not require a JSON body")
        let wrongCode = await store.signInSMS(phone: "13800000000", code: "000000")
        precondition(!wrongCode && !store.isSignedIn && secrets.saved == nil)
        let signedIn = await store.signInSMS(phone: "13800000000", code: "123456")
        precondition(signedIn && store.isSignedIn && secrets.saved != nil)
        let userId = store.userId!
        let restored = TalkTuckAccountStore(baseURL: url, credentials: secrets, deviceId: UUID())
        await restored.restore()
        precondition(restored.isSignedIn && restored.userId == userId)
        let offlineConfig = URLSessionConfiguration.ephemeral;offlineConfig.protocolClasses = [OfflineAccountProtocol.self]
        let offline = TalkTuckAccountStore(baseURL:url,session:URLSession(configuration:offlineConfig),credentials:secrets,deviceId:UUID())
        await offline.restore();precondition(offline.userId == userId && offline.isSignedIn && offline.librarySyncAvailable,"verified account cache must open when offline")
        let deniedConfig = URLSessionConfiguration.ephemeral;deniedConfig.protocolClasses = [NetworkDeniedAccountProtocol.self]
        let denied = TalkTuckAccountStore(baseURL:url,session:URLSession(configuration:deniedConfig),credentials:secrets,deviceId:UUID())
        await denied.restore();precondition(denied.userId == userId && denied.isSignedIn,"native EPERM must retain the verified account")
        store.signOut(); precondition(!store.isSignedIn && secrets.saved == nil)
        let again = await store.signInPassword(username: "qa_mac_integrity", password: "synthetic-password")
        precondition(again && store.userId != userId)
        let otherAccount = store.userId!
        let rejected = await store.signInPassword(username: "qa_mac_integrity", password: "wrong-password")
        precondition(!rejected && store.userId == otherAccount && secrets.saved?.userId == otherAccount)
        secrets.saved?.userId = UUID()
        let mismatched = TalkTuckAccountStore(baseURL: url, credentials: secrets, deviceId: UUID())
        await mismatched.restore(); precondition(!mismatched.isSignedIn)
        store.signOut()

        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [DelayedLogin.self]
        let delayedSecrets = MemorySession()
        let delayed = TalkTuckAccountStore(baseURL: URL(string: "https://fixture.invalid")!, session: URLSession(configuration: sessionConfig), credentials: delayedSecrets, deviceId: UUID())
        let task = Task { await delayed.signInPassword(username: "qa_late", password: "synthetic-password") }
        try await Task.sleep(nanoseconds: 30_000_000)
        delayed.signOut()
        let accepted = await task.value
        precondition(!accepted && !delayed.isSignedIn && delayedSecrets.saved == nil, "late response after sign-out must not restore credentials")
        print("PASS: live loopback SMS 204/sign-in, canonical identity, restore, sign-out, account isolation, failed login and stale callback protection; no real SMS, recordings or user Keychain touched")
    }
}
