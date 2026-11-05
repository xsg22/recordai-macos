import Foundation
import AppKit

@MainActor private final class StartupCredentials: TalkTuckSessionStorage {
    var saved: TalkTuckSession?
    var lockedReads: Int
    var reads = 0
    init(_ value: TalkTuckSession?, lockedReads: Int = 0) { saved = value; self.lockedReads = lockedReads }
    func read() throws -> TalkTuckSession? {
        reads += 1
        if lockedReads > 0 { lockedReads -= 1; throw TalkTuckAccountError.keychainTemporarilyUnavailable }
        return saved
    }
    func write(_ value: TalkTuckSession?) throws { saved = value }
}

private final class StartupOffline: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@main struct AgentColdStartSmoke {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let server = URL(string: "https://cold-start.invalid/talktuck")!
        let userA = UUID(), userB = UUID()
        func cached(_ user: UUID, expired: Bool = false) -> TalkTuckSession {
            TalkTuckSession(server: server.absoluteString, token: "synthetic-fixture-token", userId: user,
                loginSubject: "fixture-login-subject", expiresAt: Date().addingTimeInterval(expired ? -60 : 3600),
                displayName: "Fixture", librarySyncAvailable: true)
        }
        func seed(_ name: String) throws -> (URL, UUID, UUID) {
            let directory = root.appendingPathComponent(name)
            let library = try MeetingLibrary(root: directory)
            var a = MeetingRecord(title: "Account A final", text: "Synthetic final transcript A")
            a.userId = userA; library.activeSyncUserId = userA; _ = try library.save(a)
            var b = MeetingRecord(title: "Account B final", text: "Synthetic final transcript B")
            b.userId = userB; library.activeSyncUserId = userB; _ = try library.save(b)
            library.activeSyncUserId = userA; library.republishAgentData()
            return (directory, a.id, b.id)
        }
        func store(_ credentials: StartupCredentials) -> TalkTuckAccountStore {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StartupOffline.self]
            return TalkTuckAccountStore(baseURL: server, session: URLSession(configuration: configuration), credentials: credentials, deviceId: UUID())
        }
        func state(_ root: URL, _ account: TalkTuckAccountStore) -> AppState {
            AppState(storageURL: root, connectionNamespace: "cold-start-fixture-" + root.lastPathComponent, speechModelStore: ASRModelStore(root: root.appendingPathComponent("Models"), manifest: nil), cloudAccount: account)
        }
        func published(_ root: URL) throws -> [AgentRecording] {
            try AgentReadStore(root: root.appendingPathComponent("AgentData")).list()
        }
        func waitFor(_ root: URL, id: UUID, account: TalkTuckAccountStore, seconds: Double = 3) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if account.isSignedIn && !account.busy && !account.needsRestoreRetry,
                   (try? published(root).contains(where: { $0.id == id })) == true { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            preconditionFailure("Account transcript was not published without a window")
        }
        let (aRoot, aID, bID) = try seed("offline-cached")
        let credentials = StartupCredentials(cached(userA)), account = store(credentials)
        let beforeEvents = try AgentReadStore(root: aRoot.appendingPathComponent("AgentData")).changes(since: 0).cursor
        let app = state(aRoot, account) // Do not call restore(), MainView or a window lifecycle callback.
        let immediate = try published(aRoot)
        precondition(immediate.map(\.id) == [aID], "Startup must not erase the last valid Agent snapshot before identity resolves")
        app.startAccountRestoration() // Idempotent even if a second caller requests startup.
        try await waitFor(aRoot, id: aID, account: account)
        let visible = try published(aRoot)
        precondition(visible.map(\.id) == [aID] && !visible.contains { $0.id == bID })
        precondition(visible[0].finalText == "Synthetic final transcript A" && credentials.reads == 1)
        let startupEvents = try AgentReadStore(root: aRoot.appendingPathComponent("AgentData")).changes(since: beforeEvents)
        precondition(!startupEvents.events.contains { $0.id == aID && $0.kind == "deleted" }, "Startup must not publish a false deletion")
        account.signOut()
        let afterSignOut = try published(aRoot)
        precondition(afterSignOut.isEmpty, "Sign-out must remove account-owned Agent snapshots")

        let (bRoot, otherAID, otherBID) = try seed("other-account")
        let bAccount = store(StartupCredentials(cached(userB)))
        let bApp = state(bRoot, bAccount)
        try await waitFor(bRoot, id: otherBID, account: bAccount)
        let bVisible = try published(bRoot)
        precondition(bVisible.map(\.id) == [otherBID])
        precondition(!bVisible.contains { $0.id == otherAID })

        let (lockedRoot, lockedAID, _) = try seed("locked-keychain")
        let lockedCredentials = StartupCredentials(cached(userA), lockedReads: 2)
        let lockedAccount = store(lockedCredentials), lockedApp = state(lockedRoot, lockedAccount)
        try await waitFor(lockedRoot, id: lockedAID, account: lockedAccount, seconds: 10)
        precondition(lockedCredentials.reads == 3 && !lockedAccount.needsRestoreRetry)

        let (brokenRoot, brokenID, _) = try seed("broken-sync-state")
        let syncDirectory = brokenRoot.appendingPathComponent("Sync")
        let brokenLibrary = try MeetingLibrary(root: brokenRoot)
        let brokenAdapter = MacLibrarySyncAdapter(library: brokenLibrary)
        let brokenSync = LibrarySyncEngine(root: syncDirectory, adapter: brokenAdapter)
        try brokenSync.connect(userId: userA, server: server, transport: LibrarySyncHTTP(server: server, token: "synthetic-fixture-token"), polling: false)
        brokenSync.disconnect()
        for file in FileManager.default.enumerator(at: syncDirectory, includingPropertiesForKeys: nil)!.allObjects.compactMap({ $0 as? URL }) where file.lastPathComponent == "state.json" {
            try Data("corrupt-fixture".utf8).write(to: file)
        }
        let brokenAccount = store(StartupCredentials(cached(userA))), brokenApp = state(brokenRoot, brokenAccount)
        try await waitFor(brokenRoot, id: brokenID, account: brokenAccount)
        precondition(brokenAccount.isSignedIn, "Sync cache failure must not sign the local account out")

        let (expiredRoot, _, _) = try seed("expired-credential")
        let expiredAccount = store(StartupCredentials(cached(userA, expired: true)))
        let expiredApp = state(expiredRoot, expiredAccount)
        try await Task.sleep(nanoseconds: 150_000_000)
        let expiredVisible = try published(expiredRoot)
        precondition(!(expiredAccount.isSignedIn) && expiredVisible.isEmpty)

        let (cancelledRoot, _, _) = try seed("signout-during-retry")
        let cancelledCredentials = StartupCredentials(cached(userA), lockedReads: 1)
        let cancelledAccount = store(cancelledCredentials), cancelledApp = state(cancelledRoot, cancelledAccount)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(cancelledAccount.needsRestoreRetry)
        cancelledAccount.signOut()
        try await Task.sleep(nanoseconds: 3_200_000_000)
        precondition(!cancelledAccount.isSignedIn && !cancelledAccount.needsRestoreRetry && cancelledCredentials.reads == 1)
        let cancelledVisible = try published(cancelledRoot)
        precondition(cancelledVisible.isEmpty)
        precondition(NSApplication.shared.windows.isEmpty, "The test must not open a window")
        withExtendedLifetime([app, bApp, lockedApp, brokenApp, expiredApp, cancelledApp]) {}
        print("PASS: window-free offline startup, cached snapshot retained without false deletion, locked-Keychain retry, broken sync cache, idempotent startup, sign-out, expired credentials, account isolation and sign-out during retry; synthetic data only")
    }
}
