import Foundation
@MainActor final class MemoryCredentials: TalkTuckSessionStorage {
    var saved: TalkTuckSession?
    func read() throws -> TalkTuckSession? { saved }
    func write(_ session: TalkTuckSession?) throws { saved = session }
}
@main struct HotwordSyncE2E {
    @MainActor static func main() async throws {
        let url = URL(string: CommandLine.arguments[1])!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = PersonalHotwords(root: root.appendingPathComponent("a")), b = PersonalHotwords(root: root.appendingPathComponent("b"))
        let authA = TalkTuckAccountStore(baseURL:url, credentials:MemoryCredentials(), deviceId:UUID())
        let authB = TalkTuckAccountStore(baseURL:url, credentials:MemoryCredentials(), deviceId:UUID())
        let syncA = HotwordSync(hotwords:a,automatic:false), syncB = HotwordSync(hotwords:b,automatic:false)
        authA.onSessionChange = { syncA.connect(authA.syncAccess) }; authB.onSessionChange = { syncB.connect(authB.syncAccess) }
        precondition(a.add("本机项目"))
        let okA = await authA.signInPassword(username:"hotwords_e2e_a",password:"synthetic-password")
        let okB = await authB.signInPassword(username:"hotwords_e2e_a",password:"synthetic-password")
        precondition(okA && okB)
        await syncA.synchronize(); await syncB.synchronize()
        precondition(a.words == ["本机项目"] && b.words == ["本机项目"], "a=\(a.words) b=\(b.words) A=\(syncA.status) B=\(syncB.status)")
        a.remove("本机项目"); precondition(a.add("苹果项目")); precondition(b.add("香蕉项目"))
        await syncB.synchronize(); await syncA.synchronize(); await syncB.synchronize()
        precondition(Set(a.words) == Set(["苹果项目","香蕉项目"]) && Set(a.words) == Set(b.words))
        var arm = URLRequest(url:url.appendingPathComponent("test/arm-conflict")); arm.httpMethod = "POST"
        arm.setValue("application/json",forHTTPHeaderField:"Content-Type")
        arm.httpBody = try JSONSerialization.data(withJSONObject:["word":"并发项目"])
        _ = try await URLSession.shared.data(for:arm)
        precondition(a.add("离线项目")); await syncA.synchronize(); await syncB.synchronize()
        precondition(Set(a.words) == Set(["苹果项目","香蕉项目","并发项目","离线项目"]) && Set(a.words) == Set(b.words))
        let id = a.accountID!, reload = PersonalHotwords(root:root.appendingPathComponent("a"))
        try reload.activate(account:id); precondition(Set(reload.words) == Set(a.words) && reload.syncVersion == a.syncVersion)
        authA.signOut()
        let okOther = await authA.signInPassword(username:"hotwords_e2e_b",password:"synthetic-password")
        precondition(okOther); await syncA.synchronize(); precondition(a.words.isEmpty)
        precondition(a.add("第二账号")); await syncA.synchronize(); await syncB.synchronize(); precondition(!b.words.contains("第二账号"))
        let c = PersonalHotwords(root:root.appendingPathComponent("c")), d = PersonalHotwords(root:root.appendingPathComponent("d"))
        let authC = TalkTuckAccountStore(baseURL:url,credentials:MemoryCredentials(),deviceId:UUID())
        let authD = TalkTuckAccountStore(baseURL:url,credentials:MemoryCredentials(),deviceId:UUID())
        let syncC = HotwordSync(hotwords:c,pollInterval:100_000_000), syncD = HotwordSync(hotwords:d,pollInterval:100_000_000)
        authC.onSessionChange = { syncC.connect(authC.syncAccess) }; authD.onSessionChange = { syncD.connect(authD.syncAccess) }
        let okC = await authC.signInPassword(username:"hotwords_e2e_a",password:"synthetic-password")
        let okD = await authD.signInPassword(username:"hotwords_e2e_a",password:"synthetic-password")
        precondition(okC && okD && c.add("自动同步项目"))
        for _ in 0..<60 where !d.words.contains("自动同步项目") { try await Task.sleep(nanoseconds:100_000_000) }
        precondition(d.words.contains("自动同步项目")); authC.signOut(); authD.signOut()
        let saved = MemoryCredentials(), restoreRoot = root.appendingPathComponent("restore")
        let authFirst = TalkTuckAccountStore(baseURL:url,credentials:saved,deviceId:UUID())
        let first = HotwordSync(hotwords:PersonalHotwords(root:restoreRoot),automatic:false)
        authFirst.onSessionChange = { first.connect(authFirst.syncAccess) }
        let okFirst = await authFirst.signInPassword(username:"hotwords_e2e_a",password:"synthetic-password"); precondition(okFirst)
        let restoredWords = PersonalHotwords(root:restoreRoot)
        let restoredSync = HotwordSync(hotwords:restoredWords,automatic:false)
        let authRestored = TalkTuckAccountStore(baseURL:url,credentials:saved,deviceId:UUID())
        authRestored.onSessionChange = { restoredSync.connect(authRestored.syncAccess) }
        await authRestored.restore(); await restoredSync.synchronize()
        precondition(authRestored.isSignedIn && restoredWords.words.contains("自动同步项目"))
        authRestored.signOut(); precondition(saved.saved == nil)
        print("Existing TalkTuck login, auto sync, offline merge, forced conflict, session restore and account isolation passed")
    }
}
