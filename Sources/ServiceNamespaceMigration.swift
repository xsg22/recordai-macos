import Foundation
import CryptoKit

/// Relocates only this account's persisted sync state after a same-origin API path change.
/// Old state is retained. An ambiguous existing destination stops migration without merging edits.
enum ServiceNamespaceMigration {
    enum Failure: Error { case invalidState, conflictingState }
    static func scope(_ server: URL) -> String {
        SHA256.hash(data:Data(server.absoluteString.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    static func run(root: URL, userId: UUID, from: URL, to: URL) throws {
        if from == to { return }
        let port: (URL) -> Int? = { $0.port ?? ($0.scheme == "https" ? 443 : $0.scheme == "http" ? 80 : nil) }
        guard to.scheme == "https" || (to.scheme == "http" && ["127.0.0.1","localhost","::1"].contains(to.host ?? "")),
              from.scheme == to.scheme, from.host?.lowercased() == to.host?.lowercased(), port(from) == port(to) else { throw Failure.invalidState }
        for endpoint in [from,to] {
            guard endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else { throw Failure.invalidState }
        }
        let fm = FileManager.default, owner = userId.uuidString.lowercased()
        let source = root.appendingPathComponent(scope(from)).appendingPathComponent(owner)
        let target = root.appendingPathComponent(scope(to)).appendingPathComponent(owner)
        for directory in [root,source.deletingLastPathComponent(),target.deletingLastPathComponent()] where fm.fileExists(atPath:directory.path) {
            guard (try directory.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw Failure.invalidState }
        }
        guard fm.fileExists(atPath:source.path) else { return }
        guard (try source.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw Failure.invalidState }
        if let entries = fm.enumerator(at:source,includingPropertiesForKeys:[.isSymbolicLinkKey]) {
            for case let entry as URL in entries {
                guard (try entry.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else { throw Failure.invalidState }
            }
        }
        let names = ["state.json","AudioTransfers/queue.json"]
        var states: [String:[String:Any]] = [:], digest = SHA256()
        for name in names {
            let file = source.appendingPathComponent(name)
            guard fm.fileExists(atPath:file.path) else { continue }
            let data = try Data(contentsOf:file)
            guard let state = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  state["schemaVersion"] as? Int == 1,
                  (state["userId"] as? String)?.lowercased() == owner,
                  state["server"] as? String == from.absoluteString else { throw Failure.invalidState }
            states[name] = state; digest.update(data:Data(name.utf8)); digest.update(data:data)
        }
        guard !states.isEmpty else { return }
        let fingerprint = digest.finalize().map { String(format:"%02x",$0) }.joined()
        let marker = ".talktuck-service-migration.json"
        if fm.fileExists(atPath:target.path) {
            guard (try target.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true,
                  let data = try? Data(contentsOf:target.appendingPathComponent(marker)),
                  let saved = try JSONSerialization.jsonObject(with:data) as? [String:String],
                  saved["userId"] == owner, saved["sourceDigest"] == fingerprint else { throw Failure.conflictingState }
            return
        }
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at:parent,withIntermediateDirectories:true)
        let stage = parent.appendingPathComponent(".migration-"+UUID().uuidString)
        defer { try? fm.removeItem(at:stage) }
        try fm.copyItem(at:source,to:stage)
        for (name,var state) in states {
            state["server"] = to.absoluteString
            try JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]).write(to:stage.appendingPathComponent(name),options:.atomic)
        }
        try JSONSerialization.data(withJSONObject:["userId":owner,"sourceDigest":fingerprint],options:[.sortedKeys])
            .write(to:stage.appendingPathComponent(marker),options:.atomic)
        try fm.moveItem(at:stage,to:target)
    }
}
