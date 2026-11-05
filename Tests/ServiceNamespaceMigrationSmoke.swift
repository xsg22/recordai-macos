import Foundation

@MainActor private final class MigrationCredentials: TalkTuckSessionStorage {
    var saved: TalkTuckSession?
    func read() throws -> TalkTuckSession? { saved }
    func write(_ session: TalkTuckSession?) throws { saved = session }
}

private final class MigrationIdentity: URLProtocol {
    static var userId = UUID()
    static var offline = false
    static var requested: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requested.append(request.url!)
        if Self.offline { client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet)); return }
        let data = try! JSONSerialization.data(withJSONObject:["userId":Self.userId.uuidString,"schemaVersion":1,"librarySync":true,"audioSync":true])
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ServiceNamespaceMigrationSmoke {
    @MainActor static func main() async throws {
        let old = URL(string:"https://service.example/previous")!, next = URL(string:"https://service.example/talktuck")!
        let owner = UUID(), other = UUID()
        let credentials = MigrationCredentials()
        let cached = TalkTuckSession(server:old.absoluteString,token:"synthetic-token",userId:owner,loginSubject:"synthetic-subject",expiresAt:Date().addingTimeInterval(3600),displayName:"Fixture",librarySyncAvailable:true)
        credentials.saved = cached
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MigrationIdentity.self]
        let session = URLSession(configuration:config)
        MigrationIdentity.userId = owner
        let store = TalkTuckAccountStore(baseURL:next,session:session,credentials:credentials,deviceId:UUID())
        await store.restore()
        precondition(store.userId == owner && store.previousServer == old)
        precondition(credentials.saved?.server == next.absoluteString && credentials.saved?.previousServer == old.absoluteString)
        precondition(credentials.saved?.token == cached.token && credentials.saved?.loginSubject == cached.loginSubject)
        precondition(MigrationIdentity.requested == [next.appendingPathComponent("v2/me")])
        // A restart before queue migration must retain the migration bookmark.
        let restarted = TalkTuckAccountStore(baseURL:next,session:session,credentials:credentials,deviceId:UUID())
        await restarted.restore(); precondition(restarted.previousServer == old)
        try restarted.completeServerMigration(); precondition(credentials.saved?.previousServer == nil && restarted.previousServer == nil)

        credentials.saved = cached; MigrationIdentity.offline = true
        let offline = TalkTuckAccountStore(baseURL:next,session:session,credentials:credentials,deviceId:UUID())
        await offline.restore(); precondition(offline.userId == owner && offline.previousServer == old)
        try offline.completeServerMigration()
        precondition(credentials.saved?.server == old.absoluteString,"Offline identity must not commit credential migration")
        MigrationIdentity.offline = false; MigrationIdentity.userId = other
        let mismatch = TalkTuckAccountStore(baseURL:next,session:session,credentials:credentials,deviceId:UUID())
        await mismatch.restore(); precondition(!mismatch.isSignedIn && credentials.saved?.server == old.absoluteString)
        let before = MigrationIdentity.requested.count
        credentials.saved?.server = "https://another.example/previous"
        let foreign = TalkTuckAccountStore(baseURL:next,session:session,credentials:credentials,deviceId:UUID())
        await foreign.restore(); precondition(!foreign.isSignedIn && MigrationIdentity.requested.count == before)

        let fm = FileManager.default
        let root = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("namespace-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let source = root.appendingPathComponent(ServiceNamespaceMigration.scope(old)).appendingPathComponent(owner.uuidString.lowercased())
        let target = root.appendingPathComponent(ServiceNamespaceMigration.scope(next)).appendingPathComponent(owner.uuidString.lowercased())
        let otherFolder = source.deletingLastPathComponent().appendingPathComponent(other.uuidString.lowercased())
        try fm.createDirectory(at:source.appendingPathComponent("AudioTransfers"),withIntermediateDirectories:true)
        try fm.createDirectory(at:otherFolder,withIntermediateDirectories:true)
        let isolated = Data("other-account-state".utf8); try isolated.write(to:otherFolder.appendingPathComponent("state.json"))
        let operation = UUID().uuidString
        let text: [String:Any] = ["schemaVersion":1,"userId":owner.uuidString,"server":old.absoluteString,"deviceId":"stable-device","cursor":42,"pending":[["operationId":operation,"title":"Offline edit"]],"conflicts":[["field":"title"]]]
        let audio: [String:Any] = ["schemaVersion":1,"userId":owner.uuidString,"server":old.absoluteString,"jobs":[["id":operation,"offset":2048,"direction":"upload"]]]
        let original = try JSONSerialization.data(withJSONObject:text,options:[.sortedKeys])
        try original.write(to:source.appendingPathComponent("state.json"))
        try JSONSerialization.data(withJSONObject:audio).write(to:source.appendingPathComponent("AudioTransfers/queue.json"))
        let partial = Data(repeating:0x7f,count:2048)
        try partial.write(to:source.appendingPathComponent("AudioTransfers/resumable.part"))
        try ServiceNamespaceMigration.run(root:root,userId:owner,from:old,to:next)
        for (name,expected) in [("state.json",text),("AudioTransfers/queue.json",audio)] {
            let result = try JSONSerialization.jsonObject(with:Data(contentsOf:target.appendingPathComponent(name))) as! [String:Any]
            var changed = expected; changed["server"] = next.absoluteString
            precondition(NSDictionary(dictionary:result).isEqual(to:changed),"Only service path may change")
        }
        let preservedSource = try Data(contentsOf:source.appendingPathComponent("state.json")); precondition(preservedSource == original)
        let preservedPart = try Data(contentsOf:target.appendingPathComponent("AudioTransfers/resumable.part")); precondition(preservedPart == partial)
        let preservedOther = try Data(contentsOf:otherFolder.appendingPathComponent("state.json")); precondition(preservedOther == isolated)
        try ServiceNamespaceMigration.run(root:root,userId:owner,from:old,to:next) // crash/restart is idempotent
        let targetBefore = try Data(contentsOf:target.appendingPathComponent("state.json"))
        var changed = text; changed["cursor"] = 43
        try JSONSerialization.data(withJSONObject:changed).write(to:source.appendingPathComponent("state.json"))
        expectFailure { try ServiceNamespaceMigration.run(root:root,userId:owner,from:old,to:next) }
        let preservedTarget = try Data(contentsOf:target.appendingPathComponent("state.json")); precondition(preservedTarget == targetBefore)
        try original.write(to:source.appendingPathComponent("state.json"))
        try fm.removeItem(at:target.appendingPathComponent(".talktuck-service-migration.json"))
        expectFailure { try ServiceNamespaceMigration.run(root:root,userId:owner,from:old,to:next) }
        expectFailure { try ServiceNamespaceMigration.run(root:root,userId:owner,from:old,to:URL(string:"https://another.example/talktuck")!) }
        try fm.removeItem(at:target)
        try fm.createSymbolicLink(at:source.appendingPathComponent("unexpected-link"),withDestinationURL:otherFolder)
        expectFailure { try ServiceNamespaceMigration.run(root:root,userId:owner,from:old,to:next) }
        try fm.removeItem(at:source.appendingPathComponent("unexpected-link"))
        changed = text; changed["userId"] = other.uuidString
        try JSONSerialization.data(withJSONObject:changed).write(to:source.appendingPathComponent("state.json"))
        expectFailure { try ServiceNamespaceMigration.run(root:root,userId:owner,from:old,to:next) }
        precondition(!fm.fileExists(atPath:target.path))
        print("PASS: same-origin credential restore, offline cache, identity mismatch, restart bookmark, pending edits/conflicts/audio parts, account isolation, idempotence and fail-closed collisions/symlinks/corruption")
    }
    static func expectFailure(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Migration must reject unsafe or ambiguous state") } catch {}
    }
}
