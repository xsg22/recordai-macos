import Foundation
import Combine
import CryptoKit

// Shared verbatim with the Mac client. Wire v1 is a text-only projection, not a native archive.
struct LibrarySyncSpeaker: Codable, Equatable { var id: UUID; var name: String }
struct LibrarySyncParagraph: Codable, Equatable {
    var id: UUID; var text: String; var separator: String
    var startMs: Int?; var endMs: Int?; var speakerIds: [UUID]
    enum CodingKeys: String, CodingKey { case id, text, separator, startMs, endMs, speakerIds }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(text, forKey: .text); try c.encode(separator, forKey: .separator)
        try c.encode(startMs, forKey: .startMs); try c.encode(endMs, forKey: .endMs); try c.encode(speakerIds, forKey: .speakerIds)
    }
}
struct LibrarySyncRecording: Codable, Equatable {
    var id: UUID; var title: String; var createdAt: String; var durationMs: Int?
    var source: String; var language: String; var isStarred: Bool; var groupId: UUID?
    var speakers: [LibrarySyncSpeaker]; var paragraphs: [LibrarySyncParagraph]
    var transcriptOrigin: TranscriptionOrigin? = nil
    var formalOrigin: TranscriptionOrigin { paragraphs.isEmpty ? .notGenerated : (transcriptOrigin ?? .remote) }
    enum CodingKeys: String, CodingKey { case id,title,createdAt,durationMs,source,language,isStarred,groupId,speakers,paragraphs,transcriptOrigin }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,forKey:.id);try c.encode(title,forKey:.title);try c.encode(createdAt,forKey:.createdAt)
        try c.encode(durationMs,forKey:.durationMs);try c.encode(source,forKey:.source);try c.encode(language,forKey:.language)
        try c.encode(isStarred,forKey:.isStarred);try c.encode(groupId,forKey:.groupId)
        try c.encode(speakers,forKey:.speakers);try c.encode(paragraphs,forKey:.paragraphs)
        try c.encodeIfPresent(transcriptOrigin,forKey:.transcriptOrigin)
    }
    var text: String { paragraphs.map { $0.separator + $0.text }.joined() }
}
struct LibrarySyncGroup: Codable, Equatable { var id: UUID; var name: String }
enum LibrarySyncKind: String, Codable { case group, recording }
struct LibrarySyncValue: Codable, Equatable {
    var group: LibrarySyncGroup?; var recording: LibrarySyncRecording?
    enum CodingKeys: String, CodingKey { case group, recording }
    init(group: LibrarySyncGroup?, recording: LibrarySyncRecording?) { self.group = group; self.recording = recording }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decodeIfPresent(LibrarySyncGroup.self, forKey:.group)
        recording = try c.decodeIfPresent(LibrarySyncRecording.self, forKey:.recording)
        guard (group == nil) != (recording == nil) else { throw LibrarySyncError.invalidData }
    }
    var id: UUID { group?.id ?? recording!.id }
    var kind: LibrarySyncKind { group == nil ? .recording : .group }
    var key: String { Self.key(kind, id) }
    static func key(_ kind: LibrarySyncKind, _ id: UUID) -> String { kind.rawValue + ":" + id.uuidString.lowercased() }
    static func group(_ group: LibrarySyncGroup) -> Self { Self(group: group, recording: nil) }
    static func recording(_ record: LibrarySyncRecording) -> Self { Self(group: nil, recording: record) }
}
struct LibrarySyncEntity: Codable, Equatable {
    var kind: LibrarySyncKind; var id: UUID; var version: Int; var value: LibrarySyncValue?
    var key: String { LibrarySyncValue.key(kind, id) }
}
struct LibrarySyncMutation: Codable {
    var mutationId = UUID(); var kind: LibrarySyncKind; var id: UUID; var baseVersion: Int; var value: LibrarySyncValue?
    enum CodingKeys: String, CodingKey { case mutationId,kind,id,baseVersion,value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mutationId,forKey:.mutationId);try c.encode(kind,forKey:.kind);try c.encode(id,forKey:.id)
        try c.encode(baseVersion,forKey:.baseVersion);try c.encode(value,forKey:.value)
    }
}
struct LibrarySyncConflict: Codable, Identifiable {
    var id: String; var local: LibrarySyncValue?; var remote: LibrarySyncEntity?; var base: LibrarySyncEntity?
    var title: String { local?.recording?.title ?? local?.group?.name ?? remote?.value?.recording?.title ?? remote?.value?.group?.name ?? id }
}
struct LibrarySyncPage: Codable { var schemaVersion: Int; var userId: UUID; var events: [LibrarySyncEntity]; var cursor: String; var hasMore: Bool }
struct LibrarySyncReply: Codable { var status: String; var current: LibrarySyncEntity? }
struct LibrarySyncIdentity: Codable { var userId: UUID; var schemaVersion: Int; var librarySync: Bool }
struct LibrarySyncAccess { var server: URL; var token: String; var userId: UUID }

enum LibrarySyncError: Error { case response(Int, String), invalidData, unavailable }
protocol LibrarySyncTransport {
    func identity() async throws -> LibrarySyncIdentity
    func changes(cursor: String?) async throws -> LibrarySyncPage
    func mutate(deviceId: UUID, mutation: LibrarySyncMutation) async throws -> LibrarySyncReply
}
private final class LibrarySyncNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class LibrarySyncHTTP: LibrarySyncTransport {
    let server: URL; private let token: String; private let session: URLSession
    init(server: URL, token: String, session: URLSession? = nil) {
        self.server = server; self.token = token
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 25
        self.session = session ?? URLSession(configuration: config, delegate: LibrarySyncNoRedirect(), delegateQueue: nil)
    }
    func identity() async throws -> LibrarySyncIdentity { try await request("v2/me") }
    func changes(cursor: String?) async throws -> LibrarySyncPage { try await request("v2/library/changes", cursor: cursor) }
    func mutate(deviceId: UUID, mutation: LibrarySyncMutation) async throws -> LibrarySyncReply {
        struct Body: Encodable { var deviceId: UUID; var mutation: LibrarySyncMutation }
        return try await request("v2/library/mutations", body: JSONEncoder().encode(Body(deviceId: deviceId, mutation: mutation)))
    }
    private func request<T: Decodable>(_ path: String, cursor: String? = nil, body: Data? = nil) async throws -> T {
        guard server.scheme == "https" || (server.scheme == "http" && ["127.0.0.1","localhost","::1"].contains(server.host ?? "")), server.user == nil, server.password == nil, server.query == nil, server.fragment == nil else { throw LibrarySyncError.invalidData }
        var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        var r = URLRequest(url: components.url!); r.httpMethod = body == nil ? "GET" : "POST"; r.httpBody = body
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw LibrarySyncError.invalidData }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode([String:String].self, from: data)["error"]) ?? "request_failed"
            throw LibrarySyncError.response(http.statusCode, reason)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor protocol LibrarySyncAdapter: AnyObject {
    func activate(userId: UUID?) throws
    func values(userId: UUID) throws -> [LibrarySyncValue]
    func enroll(recordingIds: Set<UUID>, userId: UUID) throws
    func enrollAll(userId: UUID) throws
    func apply(_ entity: LibrarySyncEntity, userId: UUID) throws
    func deletions(userId: UUID) throws -> Set<String>
    func remember(_ entity: LibrarySyncEntity, userId: UUID) throws
}

enum LibrarySyncCodec {
    static func stableID(_ input: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16)); bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func date(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.string(from: date) }
    static func date(_ string: String) -> Date? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.date(from: string) ?? ISO8601DateFormatter().date(from: string) }
    static func milliseconds(_ seconds: Double?) -> Int? { guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1000) else { return nil }; return Int((seconds * 1000).rounded()) }
}

@MainActor final class LibrarySyncEngine: ObservableObject {
    @Published private(set) var userId: UUID?
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var conflicts: [LibrarySyncConflict] = []
    @Published private(set) var message = "登录后默认同步全部录音、转录和分组。"
    var onProjection: (() -> Void)?
    var onEnabledChange: ((Bool) -> Void)?
    var onSynchronized: ((Set<UUID>) -> Void)?
    private struct Projection: Codable { var entity: LibrarySyncEntity; var expected: LibrarySyncValue?; var cacheOnly: Bool? = nil }
    private struct State: Codable {
        var schemaVersion = 1; var userId: UUID; var server: String; var deviceId = UUID(); var enabled = true
        var automaticEnrollmentVersion: Int? = nil
        var uncertain = Set<String>()
        var cursor: String?; var base: [String:LibrarySyncEntity] = [:]; var pending: [String:LibrarySyncMutation] = [:]
        var conflicts: [String:LibrarySyncConflict] = [:]; var history: [LibrarySyncConflict] = []; var projections: [Projection] = []
    }
    private let root: URL; private let adapter: LibrarySyncAdapter
    private var state: State?; private var stateURL: URL?; private var transport: LibrarySyncTransport?
    private var automatic = true
    private var epoch = UUID(); private var applying = false; private var debounce: Task<Void,Never>?; private var poll: Task<Void,Never>?
    init(root: URL, adapter: LibrarySyncAdapter) { self.root = root; self.adapter = adapter }

    deinit { poll?.cancel(); debounce?.cancel() }
    func connect(userId: UUID, server: URL, transport: LibrarySyncTransport, polling: Bool = true) throws {
        disconnect(); automatic = polling
        let scope = SHA256.hash(data: Data(server.absoluteString.utf8)).map { String(format:"%02x",$0) }.joined()
        let url = root.appendingPathComponent(scope).appendingPathComponent(userId.uuidString.lowercased()).appendingPathComponent("state.json")
        var loaded: State
        if FileManager.default.fileExists(atPath: url.path) {
            loaded = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard loaded.schemaVersion == 1, loaded.userId == userId, loaded.server == server.absoluteString else { throw LibrarySyncError.invalidData }
        } else { loaded = State(userId: userId, server: server.absoluteString) }
        // Upgrade the former opt-in policy once. Later explicit pauses remain account-scoped.
        if loaded.automaticEnrollmentVersion == nil { loaded.enabled = true; loaded.automaticEnrollmentVersion = 1 }
        self.state = loaded; self.stateURL = url; self.transport = transport; self.userId = userId
        try adapter.activate(userId: userId)
        try save(); try replay(); try capture(); onProjection?(); publish(); message = enabled ? "正在自动同步全部录音资料。" : "同步已暂停，本机修改会在恢复后上传。"
        if polling { poll = Task { [weak self] in
            while !Task.isCancelled { await self?.synchronize(); do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break } }
        } }
    }
    func disconnect() {
        try? capture(); epoch = UUID(); poll?.cancel(); debounce?.cancel(); poll = nil; debounce = nil
        state = nil; stateURL = nil; transport = nil; userId = nil; busy = false; enabled = false; conflicts = []; pendingCount = 0; onEnabledChange?(false)
        do { try adapter.activate(userId: nil) } catch { message = "本机资料暂时无法读取，同步已暂停。" }
    }
    func enable(recordingIds: Set<UUID> = []) {
        guard let userId, state != nil else { return }
        do {
            state!.enabled = true;
            try adapter.enrollAll(userId: userId)
            state!.enabled = true; try save(); try capture(); onProjection?(); publish(); schedule()
        } catch { message = "本机同步状态保存失败，内容已保留。" }
    }
    func pause() { epoch = UUID(); busy = false; debounce?.cancel(); state?.enabled = false; do { try save(); publish() } catch { message = "本机同步状态保存失败，内容已保留。" } }
    func localDidChange() {
        guard !applying else { return }
        do { try capture(); onProjection?(); publish(); schedule() } catch { message = "本机同步状态保存失败，内容已保留。" }
    }
    private func schedule() {
        guard enabled, automatic else { return }; debounce?.cancel()
        debounce = Task { [weak self] in do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }; await self?.synchronize() }
    }
    private func localValues() throws -> [String:LibrarySyncValue] {
        guard let userId else { return [:] }
        let rows = try adapter.values(userId: userId)
        guard Set(rows.map(\.key)).count == rows.count else { throw LibrarySyncError.invalidData }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.key,$0) })
    }
    private func capture() throws {
        guard let userId, var s = state, s.userId == userId else { return }
        applying = true; defer { applying = false }
        // Pausing stops network work, not account ownership. Otherwise recordings created
        // while paused could be claimed by the next account on this device.
        try adapter.enrollAll(userId:userId)
        guard s.enabled else { return }
        let local = try localValues(), deletions = try adapter.deletions(userId:userId)
        for key in Set(local.keys).union(s.base.keys).union(s.pending.keys) {
            let value = local[key], base = s.base[key]
            // A remote projection may wait for a recording/file lock. Its old native value is
            // not a new edit. Replay compares against expected and records genuine edits as conflicts.
            if s.projections.contains(where: { $0.entity.key == key && $0.cacheOnly != true }) { continue }
            // Absence is not a delete: an index/file may have gone missing. Require native tombstones.
            if value == nil, base?.value != nil || s.pending[key]?.value != nil,
               !deletions.contains(key), !(s.pending[key] != nil && s.pending[key]?.value == nil) { throw LibrarySyncError.invalidData }
            if var conflict = s.conflicts[key] { conflict.local = value; s.conflicts[key] = conflict; continue }
            if let pending = s.pending[key], pending.value == value { continue }
            if value == base?.value && !s.uncertain.contains(key) { s.pending.removeValue(forKey: key); continue }
            guard let id = value?.id ?? base?.id ?? s.pending[key]?.id, let kind = value?.kind ?? base?.kind ?? s.pending[key]?.kind else { continue }
            s.pending[key] = LibrarySyncMutation(kind: kind, id: id, baseVersion: base?.version ?? 0, value: value)
        }
        state = s; try save()
    }
    private func save() throws {
        guard let state, let url = stateURL else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
    private func publish() {
        let wasEnabled = enabled
        enabled = state?.enabled ?? false
        if wasEnabled != enabled { onEnabledChange?(enabled) }
        pendingCount = state?.pending.count ?? 0
        conflicts = (state?.conflicts.values.map { $0 } ?? []).sorted { $0.id < $1.id }
    }
    private func replay() throws {
        guard let userId else { return }
        while let projection = state?.projections.first {
            let local = try localValues()[projection.entity.key]
            if projection.cacheOnly == true {
                applying = true; defer { applying = false }
                try adapter.remember(projection.entity,userId:userId)
            } else if local != projection.expected && local != projection.entity.value {
                state!.conflicts[projection.entity.key] = LibrarySyncConflict(id: projection.entity.key, local: local, remote: projection.entity, base: nil)
            } else if local != projection.entity.value {
                applying = true; defer { applying = false }
                try adapter.apply(projection.entity, userId: userId)
            }
            state!.projections.removeFirst(); try save()
        }
        onProjection?()
    }
    private func accept(_ remote: LibrarySyncEntity) throws {
        guard remote.version > 0, remote.value == nil || (remote.value?.id == remote.id && remote.value?.kind == remote.kind) else { throw LibrarySyncError.invalidData }
        let key = remote.key
        guard remote.version > (state?.base[key]?.version ?? 0) else { return }
        let local = try localValues()[key], oldBase = state?.base[key]
        if state?.pending[key] != nil || state?.conflicts[key] != nil {
            if local == remote.value { state!.pending.removeValue(forKey:key); state!.conflicts.removeValue(forKey:key); state!.uncertain.remove(key) }
            else { state!.conflicts[key] = LibrarySyncConflict(id:key,local:local,remote:remote,base:oldBase) }
        } else if let index = state!.projections.firstIndex(where: { $0.entity.key == key }) {
            state!.projections[index].entity = remote
        } else { state!.projections.append(Projection(entity:remote,expected:local)) }
        state!.base[key] = remote
    }
    func resolve(_ key: String, useLocal: Bool) {
        guard state != nil else { return }
        do {
            try capture(); guard let conflict = state?.conflicts[key] else { return }
            state!.history.append(conflict); state!.conflicts.removeValue(forKey:key); state!.uncertain.remove(key)
            if useLocal {
                guard let id = conflict.local?.id ?? conflict.remote?.id, let kind = conflict.local?.kind ?? conflict.remote?.kind else { throw LibrarySyncError.invalidData }
                state!.pending[key] = LibrarySyncMutation(kind:kind,id:id,baseVersion:conflict.remote?.version ?? 0,value:conflict.local)
            } else {
                state!.pending.removeValue(forKey:key)
                if let remote = conflict.remote { state!.projections.append(Projection(entity:remote,expected:conflict.local)) }
            }
            try save(); try replay(); publish(); schedule()
        } catch { message = "冲突处理未完成，双方版本已保留。" }
    }
    func synchronize() async {
        guard !busy, enabled, let userId, let transport, state != nil else { return }
        let generation = epoch; busy = true; defer { if generation == epoch { busy = false; publish() } }
        do {
            try capture()
            let identity = try await transport.identity()
            guard generation == epoch else { return }
            guard identity.userId == userId, identity.schemaVersion == 1, identity.librarySync else { throw LibrarySyncError.invalidData }
            // Pull first so two independent offline creations and duplicate names are visible before upload.
            try await pull(transport, userId: userId, generation: generation)
            guard generation == epoch else { return }
            let pendingSnapshot = state!.pending
            let keys = pendingSnapshot.keys.sorted { a,b in
                func order(_ key:String)->Int { guard let m = pendingSnapshot[key] else { return 4 };return m.kind == .group ? (m.value == nil ? 3 : 0) : 1 }
                return order(a) == order(b) ? a < b : order(a) < order(b)
            }
            for key in keys.prefix(100) {
                guard generation == epoch, state!.conflicts[key] == nil, let mutation = state!.pending[key] else { continue }
                state!.uncertain.insert(key); try save()
                let reply = try await transport.mutate(deviceId:state!.deviceId,mutation:mutation)
                guard generation == epoch else { return }; try capture()
                if reply.status == "applied", let remote = reply.current {
                    guard remote.id == mutation.id, remote.kind == mutation.kind else { throw LibrarySyncError.invalidData }
                    state!.base[key] = remote; state!.uncertain.remove(key)
                    state!.projections.append(Projection(entity:remote,expected:nil,cacheOnly:true))
                    if state!.pending[key]?.value == remote.value { state!.pending.removeValue(forKey:key) }
                    else if let latest = state!.pending[key] { state!.pending[key] = LibrarySyncMutation(kind:latest.kind,id:latest.id,baseVersion:remote.version,value:latest.value) }
                } else if reply.status == "conflict" {
                    state!.conflicts[key] = LibrarySyncConflict(id:key,local:try localValues()[key],remote:reply.current,base:state!.base[key])
                    if let remote = reply.current { state!.base[key] = remote }
                } else { throw LibrarySyncError.invalidData }
                try save(); try replay()
            }
            try await pull(transport, userId:userId,generation:generation)
            guard generation == epoch else { return }
            message = state!.conflicts.isEmpty ? (state!.pending.isEmpty ? "文字与分组已同步。" : "部分修改等待同步。") : "存在冲突，双方版本已保留。"
            let acknowledged = Set(state!.base.values.filter {
                entity in entity.kind == .recording && entity.value != nil && state!.pending[entity.key] == nil && state!.conflicts[entity.key] == nil && !state!.projections.contains(where: { $0.entity.key == entity.key && $0.cacheOnly != true })
            }.map(\.id))
            onSynchronized?(acknowledged)
        } catch {
            guard generation == epoch else { return }
            message = "暂时无法同步，离线修改已保留。"
            if case LibrarySyncError.response(_,let reason) = error, reason == "name_conflict" { message = "云端存在同名分组，请重命名后重试。" }
            if case LibrarySyncError.response(_,let reason) = error, reason == "dependency_missing" { message = "所属分组已变化，请重新选择分组后同步。" }
        }
    }
    private func pull(_ transport:LibrarySyncTransport,userId:UUID,generation:UUID) async throws {
        for _ in 0..<1000 {
            let page:LibrarySyncPage
            do { page = try await transport.changes(cursor:state?.cursor) }
            catch LibrarySyncError.response(410,_) { guard generation == epoch else { return };state!.cursor = nil;try save();continue }
            guard generation == epoch else { return }
            guard page.userId == userId, page.schemaVersion == 1 else { throw LibrarySyncError.invalidData }
            try capture()
            for entity in page.events { try accept(entity) }
            state!.cursor = page.cursor; try save(); try replay(); publish()
            if !page.hasMore { return }
        }
        throw LibrarySyncError.unavailable
    }
}
