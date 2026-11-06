import Foundation

/// Production cache selection never reads a developer's persisted scratch path.
enum LiveRefinementCache {
    static let legacyPreferenceKey = "LivePreviewScratchDirectory"
    static func discardLegacyOverride(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyPreferenceKey)
        defaults.removeObject(forKey: "LiveHotwordModelDirectory")
    }
    static func prepare(baseURL: URL? = nil) throws -> URL {
        let manager = FileManager.default
        let base: URL
        if let baseURL {
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: baseURL.path, isDirectory: &directory), directory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
            base = baseURL
        } else {
            base = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        let root = base.appendingPathComponent("com.xsg.talktuck/LiveRefinement", isDirectory: true)
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CocoaError(.fileWriteNoPermission) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard manager.isWritableFile(atPath: root.path) else { throw CocoaError(.fileWriteNoPermission) }
        return root
    }
}
