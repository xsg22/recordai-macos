import Foundation
import Combine
import CryptoKit

struct LibraryAudioPart: Codable, Equatable, Identifiable {
    var id: UUID; var recordingId: UUID; var sha256: String; var byteLength: Int
    var mimeType: String; var durationMs: Int; var timelineStartMs: Int
    var fileExtension: String { ["audio/mp4":"m4a","audio/wav":"wav","audio/mpeg":"mp3","audio/aiff":"aiff","audio/x-caf":"caf"][mimeType] ?? "bin" }
}
struct LibraryAudioManifest: Codable, Equatable { var recordingId: UUID; var version: Int; var parts: [LibraryAudioPart] }
// Retain exact downloaded originals even when iPhone needs a derived file for multipart playback.
struct LibraryAudioArchive: Codable, Equatable { var manifest: LibraryAudioManifest; var filenames: [String] }
struct LibraryAudioSource { var url: URL; var durationMs: Int; var timelineStartMs: Int }
struct LibraryAudioUpload: Codable { var uploadId: UUID; var chunkSize: Int; var received: [Int]; var complete: Bool }
enum LibraryAudioError: Error { case invalid, changed, conflict, cancelled, integrity, canonicalProtocolRequired, response(Int) }

struct LibraryAudioCandidate {
    var recordingId: UUID; var revision: String?
    static func revision(_ urls: [URL]) throws -> String? {
        guard !urls.isEmpty else { return nil }
        var rows: [String] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath:url.path) else { return nil }
            let a = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard a.isRegularFile == true, a.isSymbolicLink != true, let size = a.fileSize, size > 0, let date = a.contentModificationDate else { throw LibraryAudioError.invalid }
            rows.append(url.lastPathComponent + ":" + String(size) + ":" + String(date.timeIntervalSince1970))
        }
        return LibraryAudioFiles.hash(Data(rows.joined(separator:"\n").utf8))
    }
}
@MainActor protocol LibraryAudioAdapter: AnyObject {
    func automaticCandidates(userId: UUID) throws -> [LibraryAudioCandidate]
    func sources(_ id: UUID, userId: UUID) async throws -> [LibraryAudioSource]
    func install(_ manifest: LibraryAudioManifest, files: [URL], userId: UUID) async throws
}
extension LibraryAudioAdapter {
    func automaticCandidates(userId: UUID) throws -> [LibraryAudioCandidate] { [] }
}
protocol LibraryAudioTransport {
    func available(userId: UUID) async throws -> Bool
    func manifest(_ id: UUID) async throws -> LibraryAudioManifest?
    func start(_ part: LibraryAudioPart) async throws -> LibraryAudioUpload
    func upload(_ part: LibraryAudioPart, index: Int, bytes: Data) async throws
    func seal(_ part: LibraryAudioPart) async throws
    func publish(_ id: UUID, base: Int, parts: [LibraryAudioPart]) async throws -> LibraryAudioManifest
    func download(_ part: LibraryAudioPart, index: Int) async throws -> Data
}
private final class AudioNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class LibraryAudioHTTP: LibraryAudioTransport {
    private let server: URL; private let token: String; private let session: URLSession
    init(server: URL, token: String, session: URLSession? = nil) {
        self.server = server;self.token = token
        let c = URLSessionConfiguration.ephemeral;c.httpShouldSetCookies = false;c.urlCache = nil;c.timeoutIntervalForRequest = 45
        self.session = session ?? URLSession(configuration:c,delegate:AudioNoRedirect(),delegateQueue:nil)
    }
    private func call(_ path: String, method: String = "GET", body: Data? = nil, binary: Bool = false) async throws -> (Data,HTTPURLResponse) {
        guard server.scheme == "https" || (server.scheme == "http" && ["localhost","127.0.0.1","::1"].contains(server.host ?? "")),server.user == nil,server.password == nil,server.query == nil,server.fragment == nil else { throw LibraryAudioError.invalid }
        var r = URLRequest(url:server.appendingPathComponent(path));r.httpMethod = method;r.httpBody = body
        r.setValue("Bearer " + token,forHTTPHeaderField:"Authorization")
        if body != nil { r.setValue(binary ? "application/octet-stream" : "application/json",forHTTPHeaderField:"Content-Type") }
        if binary,let body { r.setValue(LibraryAudioFiles.hash(body),forHTTPHeaderField:"X-Content-SHA256") }
        let (data,response) = try await session.data(for:r)
        guard let http = response as? HTTPURLResponse else { throw LibraryAudioError.invalid }
        guard (200..<300).contains(http.statusCode) else { throw LibraryAudioError.response(http.statusCode) }
        return (data,http)
    }
    func available(userId: UUID) async throws -> Bool {
        struct Identity: Decodable { var userId: UUID; var audioSync: Bool }
        let i = try JSONDecoder().decode(Identity.self,from:try await call("v2/me").0)
        guard i.userId == userId else { throw LibraryAudioError.invalid };return i.audioSync
    }
    private func path(_ id: UUID) -> String { "v2/library/audio/recordings/" + id.uuidString.lowercased() }
    func manifest(_ id: UUID) async throws -> LibraryAudioManifest? {
        do { return try JSONDecoder().decode(LibraryAudioManifest.self,from:try await call(path(id)).0) }
        catch LibraryAudioError.response(404) { return nil }
    }
    func start(_ part: LibraryAudioPart) async throws -> LibraryAudioUpload { try JSONDecoder().decode(LibraryAudioUpload.self,from:try await call("v2/library/audio/uploads",method:"POST",body:JSONEncoder().encode(part)).0) }
    func upload(_ part: LibraryAudioPart, index: Int, bytes: Data) async throws { _ = try await call("v2/library/audio/uploads/\(part.id.uuidString.lowercased())/\(index)",method:"PUT",body:bytes,binary:true) }
    func seal(_ part: LibraryAudioPart) async throws {
        let p = try JSONDecoder().decode(LibraryAudioPart.self,from:try await call("v2/library/audio/uploads/\(part.id.uuidString.lowercased())/complete",method:"POST").0)
        guard p == part else { throw LibraryAudioError.integrity }
    }
    func publish(_ id: UUID, base: Int, parts: [LibraryAudioPart]) async throws -> LibraryAudioManifest {
        struct Body: Encodable { var baseVersion: Int; var parts: [LibraryAudioPart] }
        do { return try JSONDecoder().decode(LibraryAudioManifest.self,from:try await call(path(id),method:"PUT",body:JSONEncoder().encode(Body(baseVersion:base,parts:parts))).0) }
        catch LibraryAudioError.response(409) { throw LibraryAudioError.conflict }
    }
    func download(_ part: LibraryAudioPart, index: Int) async throws -> Data {
        let (data,response) = try await call(path(part.recordingId)+"/\(part.id.uuidString.lowercased())/\(index)")
        guard data.count <= LibraryAudioFiles.chunkSize, response.value(forHTTPHeaderField:"X-Content-SHA256") == LibraryAudioFiles.hash(data) else { throw LibraryAudioError.integrity };return data
    }
}

enum LibraryAudioFiles {
    static let chunkSize = 2*1024*1024
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func digest(_ url: URL) throws -> (String,Int) {
        guard url.isFileURL,try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]).isRegularFile == true,try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw LibraryAudioError.invalid }
        let f = try FileHandle(forReadingFrom:url);defer { try? f.close() };var hash = SHA256();var count = 0
        while let data = try f.read(upToCount:chunkSize), !data.isEmpty { count += data.count;guard count <= 512*1024*1024 else { throw LibraryAudioError.invalid };hash.update(data:data) }
        guard count > 0 else { throw LibraryAudioError.invalid };return (hash.finalize().map { String(format:"%02x",$0) }.joined(),count)
    }
    static func describe(_ source: LibraryAudioSource, recordingId: UUID) throws -> LibraryAudioPart {
        let mime = ["m4a":"audio/mp4","mp4":"audio/mp4","wav":"audio/wav","mp3":"audio/mpeg","aiff":"audio/aiff","aif":"audio/aiff","caf":"audio/x-caf"][source.url.pathExtension.lowercased()]
        guard let mime,source.durationMs > 0,source.timelineStartMs >= 0 else { throw LibraryAudioError.invalid }
        let (sha,size) = try digest(source.url)
        let id = LibrarySyncCodec.stableID(recordingId.uuidString.lowercased()+":audio:\(sha):\(source.timelineStartMs):\(source.durationMs)")
        return LibraryAudioPart(id:id,recordingId:recordingId,sha256:sha,byteLength:size,mimeType:mime,durationMs:source.durationMs,timelineStartMs:source.timelineStartMs)
    }
    static func validate(_ m: LibraryAudioManifest, id: UUID) throws {
        guard m.recordingId == id,m.version > 0,!m.parts.isEmpty,m.parts.count <= 4096,Set(m.parts.map(\.id)).count == m.parts.count else { throw LibraryAudioError.invalid }
        var end = 0
        for p in m.parts {
            guard p.recordingId == id,p.sha256.count == 64,p.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),p.byteLength > 0,p.byteLength <= 512*1024*1024,p.durationMs > 0,p.durationMs <= 86_400_000,p.timelineStartMs >= end,p.timelineStartMs <= 86_400_000,p.fileExtension != "bin" else { throw LibraryAudioError.invalid };end = p.timelineStartMs+p.durationMs
        }
    }
    static func directory(_ url: URL) throws {
        // iPhone document URLs and macOS temporary URLs may use Apple's /var or /tmp aliases.
        // Normalize only those OS aliases; continue to reject symlinks inside managed storage.
        var p = url
        for alias in ["/var","/tmp"] where p.path == alias || p.path.hasPrefix(alias+"/") {
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath:alias)
            if target == "private"+alias || target == "/private"+alias { p = URL(fileURLWithPath:"/private"+alias+String(p.path.dropFirst(alias.count)),isDirectory:true) }
        }
        while p.path != "/" { guard (try? p.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { throw LibraryAudioError.invalid };p.deleteLastPathComponent() }
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    static func install(_ source: URL, at destination: URL, part: LibraryAudioPart) throws {
        try directory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath:destination.path) {
            let (sha,n) = try digest(destination);guard sha == part.sha256,n == part.byteLength else { throw LibraryAudioError.integrity };return
        }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".tmp")
        defer { try? FileManager.default.removeItem(at:temp) };try FileManager.default.copyItem(at:source,to:temp)
        let (sha,n) = try digest(temp);guard sha == part.sha256,n == part.byteLength else { throw LibraryAudioError.integrity }
        try FileManager.default.moveItem(at:temp,to:destination)
    }
}

@MainActor final class LibraryAudioSyncEngine: ObservableObject {
    enum Direction: String, Codable { case upload, download }
    struct Job: Codable, Identifiable { var id = UUID();var recordingId: UUID;var direction: Direction;var parts: [LibraryAudioPart]?;var manifest: LibraryAudioManifest?;var base: Int?;var needsChoice: Bool?; var automaticRevision: String? = nil }
    private struct State: Codable { var schemaVersion = 1;var userId: UUID;var server: String;var jobs: [Job] = []; var completedRevisions: [String:String]? = nil; var remoteVersions: [String:Int]? = nil }
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var busy = false
    @Published private(set) var message = "原音会随录音资料自动同步。"
    @Published private(set) var automaticEnabled = false
    @Published private(set) var conflict: UUID?
    var onInstalled: (() -> Void)?
    private(set) var lastFailure: Error?
    private let root: URL;private let adapter: LibraryAudioAdapter
    private var automaticReadyIds = Set<UUID>()
    private var account: UUID?;private var client: LibraryAudioTransport?;private var state: State?;private var folder: URL?;private var epoch = UUID()
    init(root: URL, adapter: LibraryAudioAdapter) { self.root = root;self.adapter = adapter }
    func connect(userId: UUID, server: URL, transport: LibraryAudioTransport) throws {
        disconnect()
        let dir = root.appendingPathComponent(LibraryAudioFiles.hash(Data(server.absoluteString.utf8))).appendingPathComponent(userId.uuidString.lowercased()).appendingPathComponent("AudioTransfers")
        try LibraryAudioFiles.directory(dir)
        let file = dir.appendingPathComponent("queue.json")
        let s = FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode(State.self,from:Data(contentsOf:file)) : State(userId:userId,server:server.absoluteString)
        guard s.schemaVersion == 1,s.userId == userId,s.server == server.absoluteString else { throw LibraryAudioError.invalid }
        account = userId;client = transport;folder = dir;state = s;jobs = s.jobs
        message = jobs.isEmpty ? "原音会随录音资料自动同步。" : "原音传输尚未完成，将自动重试。"
    }
    func disconnect() { epoch = UUID();account = nil;client = nil;state = nil;folder = nil;jobs = [];busy = false;conflict = nil;automaticEnabled = false;automaticReadyIds = [] }
    func setAutomaticEnabled(_ value: Bool) {
        guard automaticEnabled != value else { return }
        automaticEnabled = value
        if !value { epoch = UUID(); busy = false; message = "同步已暂停，本机修改会在恢复后上传。" }
    }
    func synchronizeAutomatically(recordingIds: Set<UUID>) async {
        guard automaticEnabled, !busy, let account, let client else { return }
        let generation = epoch
        automaticReadyIds = recordingIds
        busy = true
        do {
            let candidates = try adapter.automaticCandidates(userId:account).filter { recordingIds.contains($0.recordingId) }
            for candidate in candidates where !jobs.contains(where: { $0.recordingId == candidate.recordingId }) {
                let key = candidate.recordingId.uuidString.lowercased()
                if let revision = candidate.revision {
                    if state?.completedRevisions?[key] == revision {
                        let remote = try await client.manifest(candidate.recordingId); try current(generation)
                        if let remote, let previous = state?.remoteVersions?[key], remote.version != previous {
                            jobs.append(Job(recordingId:candidate.recordingId,direction:.download,manifest:remote))
                        }
                    } else { jobs.append(Job(recordingId:candidate.recordingId,direction:.upload,automaticRevision:revision)) }
                } else if let remote = try await client.manifest(candidate.recordingId) {
                    try current(generation); jobs.append(Job(recordingId:candidate.recordingId,direction:.download,manifest:remote))
                }
                try save()
            }
            try current(generation); busy = false
            if !jobs.isEmpty { await retry() }
        } catch {
            guard generation == epoch else { return }
            busy = false; lastFailure = error; message = "原音传输未完成，进度已保留，可稍后重试。"
        }
    }
    private func save() throws { guard var s = state,let folder else { throw LibraryAudioError.cancelled };s.jobs = jobs;try JSONEncoder().encode(s).write(to:folder.appendingPathComponent("queue.json"),options:.atomic);state = s }
    func enqueue(_ id: UUID, direction: Direction) async {
        guard !busy,account != nil else { return }
        if !jobs.contains(where:{ $0.recordingId == id && $0.direction == direction }) { jobs.append(Job(recordingId:id,direction:direction));do { try save() } catch { message = "无法保存传输任务，未开始传输。";return } }
        await retry()
    }
    func remove(_ id: UUID) { guard !busy else { return };let old = jobs;jobs.removeAll { $0.id == id };do { try save();conflict = nil } catch { jobs = old;message = "无法保存传输状态。" } }
    // Explicit user choice required before replacing a different published original manifest.
    func replaceCloud() async {
        guard !busy,let conflict,let i = jobs.firstIndex(where:{$0.id == conflict}),let client else { return }
        let generation = epoch
        do { let remote = try await client.manifest(jobs[i].recordingId);try current(generation);jobs[i].base = remote?.version ?? 0;jobs[i].needsChoice = false;try save();self.conflict = nil;await retry() }
        catch { if generation == epoch { message = "暂时无法读取云端原音，请稍后重试。" } }
    }
    func useCloud() async {
        guard !busy, automaticEnabled, let conflict, let index = jobs.firstIndex(where: { $0.id == conflict }) else { return }
        let recordingId = jobs[index].recordingId
        jobs[index] = Job(recordingId:recordingId,direction:.download)
        do { try save(); self.conflict = nil; await retry() }
        catch { message = "无法保存传输状态。" }
    }
    private func current(_ generation: UUID) throws { guard generation == epoch,!Task.isCancelled else { throw LibraryAudioError.cancelled } }
    func retry() async {
        guard !busy,let account,let client,let folder else { return }
        let generation = epoch;busy = true;lastFailure = nil
        defer { if generation == epoch { busy = false } }
        do {
            guard try await client.available(userId:account) else { try current(generation);message = "服务暂未开启原音同步。";return };try current(generation)
            let ready = automaticEnabled ? try Set(adapter.automaticCandidates(userId:account).map(\.recordingId)).intersection(automaticReadyIds) : nil
            let snapshot = jobs.filter { ready == nil || ready!.contains($0.recordingId) }
            for first in snapshot {
                if first.needsChoice == true { continue }
                do {
                if first.direction == .upload { try await send(first,userId:account,client:client,generation:generation) }
                else { try await receive(first,userId:account,client:client,folder:folder,generation:generation) }
                try current(generation)
                let key = first.recordingId.uuidString.lowercased()
                if let revision = try adapter.automaticCandidates(userId:account).first(where: { $0.recordingId == first.recordingId })?.revision {
                    if first.direction == .upload, let scheduled = first.automaticRevision, scheduled != revision { throw LibraryAudioError.changed }
                    if state!.completedRevisions == nil { state!.completedRevisions = [:] }
                    state!.completedRevisions![key] = revision
                }
                if let manifest = jobs.first(where: { $0.id == first.id })?.manifest {
                    if state!.remoteVersions == nil { state!.remoteVersions = [:] }
                    state!.remoteVersions![key] = manifest.version
                }
                jobs.removeAll { $0.id == first.id };try save()
                } catch {
                    try current(generation); lastFailure = error
                    if case LibraryAudioError.conflict = error, let index = jobs.firstIndex(where: { $0.id == first.id }) {
                        jobs[index].needsChoice = true; try save()
                    }
                }
            }
            conflict = jobs.first(where: { $0.needsChoice == true })?.id

            if conflict != nil { message = "云端已有不同原音，请选择保留哪一版。双方原件都会保留。" }
            else if let lastFailure {
                if case LibraryAudioError.integrity = lastFailure { message = "音频校验失败，现有原件未被替换。可以重试。" }
                else if case LibraryAudioError.canonicalProtocolRequired = lastFailure { message = "分段录音暂不支持原音云同步，原音仍保存在本机。" }
                else if case LibraryAudioError.changed = lastFailure { message = "本机音频已变化，请移除此任务后重新选择。" }
                else { message = "原音传输未完成，进度已保留，可稍后重试。" }
            }
            else { message = jobs.isEmpty ? "原音传输完成，文件校验通过。" : "部分原音等待录音或转录结束后同步。" }
        } catch {
            guard generation == epoch else { return }
            lastFailure = error
            if case LibraryAudioError.conflict = error { conflict = jobs.first?.id;if !jobs.isEmpty { jobs[0].needsChoice = true;try? save() };message = "云端已有不同原音，请选择保留哪一版。双方原件都会保留。" }
            else if case LibraryAudioError.changed = error { message = "本机音频已变化，请移除此任务后重新选择。" }
            else if case LibraryAudioError.integrity = error { message = "音频校验失败，现有原件未被替换。可以重试。" }
            else { message = "原音传输未完成，进度已保留，可稍后重试。" }
        }
    }
    private func send(_ initial: Job, userId: UUID, client: LibraryAudioTransport, generation: UUID) async throws {
        if initial.needsChoice == true { throw LibraryAudioError.conflict }
        let sources = try await adapter.sources(initial.recordingId,userId:userId);try current(generation)
        let parts = try await Task.detached { try sources.map { try LibraryAudioFiles.describe($0,recordingId:initial.recordingId) } }.value;try current(generation)
        try LibraryAudioFiles.validate(LibraryAudioManifest(recordingId:initial.recordingId,version:1,parts:parts),id:initial.recordingId)
        if let previous = initial.parts,previous != parts { throw LibraryAudioError.changed }
        let remote = try await client.manifest(initial.recordingId);try current(generation)
        guard let i = jobs.firstIndex(where:{$0.id == initial.id}) else { throw LibraryAudioError.cancelled }
        jobs[i].parts = parts
        if jobs[i].base == nil { jobs[i].base = remote?.version ?? 0;try save();if let remote,remote.parts != parts { throw LibraryAudioError.conflict } }
        let base = jobs[i].base!;try save()
        // A failed response after publication is success when the manifest already matches exactly.
        if remote?.parts == parts { jobs[i].manifest = remote; try save(); return }
        if (remote?.version ?? 0) != base { throw LibraryAudioError.conflict }
        for (source,part) in zip(sources,parts) {
            let response = try await client.start(part);try current(generation)
            guard response.uploadId == part.id,response.chunkSize == LibraryAudioFiles.chunkSize else { throw LibraryAudioError.invalid }
            if !response.complete {
                let input = try FileHandle(forReadingFrom:source.url);defer { try? input.close() }
                for n in 0..<Int(ceil(Double(part.byteLength)/Double(LibraryAudioFiles.chunkSize))) where !response.received.contains(n) {
                    try input.seek(toOffset:UInt64(n*LibraryAudioFiles.chunkSize))
                    let data = try input.read(upToCount:LibraryAudioFiles.chunkSize) ?? Data()
                    guard data.count == min(LibraryAudioFiles.chunkSize,part.byteLength-n*LibraryAudioFiles.chunkSize) else { throw LibraryAudioError.changed }
                    try await client.upload(part,index:n,bytes:data);try current(generation)
                }
                let checked = try await Task.detached { try LibraryAudioFiles.describe(source,recordingId:initial.recordingId) }.value;try current(generation)
                guard checked == part else { throw LibraryAudioError.changed };try await client.seal(part);try current(generation)
            }
        }
        let published = try await client.publish(initial.recordingId,base:base,parts:parts);try current(generation)
        guard published.parts == parts else { throw LibraryAudioError.integrity }
        if let index = jobs.firstIndex(where: { $0.id == initial.id }) { jobs[index].manifest = published; try save() }
    }
    private func receive(_ initial: Job, userId: UUID, client: LibraryAudioTransport, folder: URL, generation: UUID) async throws {
        var manifest = initial.manifest
        if manifest == nil { manifest = try await client.manifest(initial.recordingId);try current(generation) }
        guard let manifest else { throw LibraryAudioError.response(404) };try LibraryAudioFiles.validate(manifest,id:initial.recordingId)
        guard let i = jobs.firstIndex(where:{$0.id == initial.id}) else { throw LibraryAudioError.cancelled };jobs[i].manifest = manifest;try save()
        var files: [URL] = []
        for part in manifest.parts {
            let directory = folder.appendingPathComponent(part.id.uuidString.lowercased());try LibraryAudioFiles.directory(directory)
            let sealed = directory.appendingPathComponent(part.sha256+"."+part.fileExtension)
            if let checked = try? LibraryAudioFiles.digest(sealed),checked.0 == part.sha256,checked.1 == part.byteLength { files.append(sealed);continue }
            let temp = directory.appendingPathComponent(UUID().uuidString+".tmp");FileManager.default.createFile(atPath:temp.path,contents:nil)
            let output = try FileHandle(forWritingTo:temp)
            do {
                for n in 0..<Int(ceil(Double(part.byteLength)/Double(LibraryAudioFiles.chunkSize))) {
                    let chunk = directory.appendingPathComponent("\(n).chunk")
                    var data = try? Data(contentsOf:chunk)
                    if data == nil { data = try await client.download(part,index:n);try current(generation);try data!.write(to:chunk,options:.atomic) }
                    guard data!.count == min(LibraryAudioFiles.chunkSize,part.byteLength-n*LibraryAudioFiles.chunkSize) else { throw LibraryAudioError.integrity }
                    try output.write(contentsOf:data!)
                }
                try output.synchronize();try output.close();try current(generation)
                let (sha,n) = try await Task.detached { try LibraryAudioFiles.digest(temp) }.value;try current(generation)
                guard sha == part.sha256,n == part.byteLength else { throw LibraryAudioError.integrity }
                if FileManager.default.fileExists(atPath:sealed.path) { try FileManager.default.removeItem(at:sealed) }
                try FileManager.default.moveItem(at:temp,to:sealed);files.append(sealed)
                for n in 0..<Int(ceil(Double(part.byteLength)/Double(LibraryAudioFiles.chunkSize))) { try? FileManager.default.removeItem(at:directory.appendingPathComponent("\(n).chunk")) }
            } catch {
                try? output.close();try? FileManager.default.removeItem(at:temp)
                if case LibraryAudioError.integrity = error { for n in 0..<Int(ceil(Double(part.byteLength)/Double(LibraryAudioFiles.chunkSize))) { try? FileManager.default.removeItem(at:directory.appendingPathComponent("\(n).chunk")) } }
                throw error
            }
        }
        try current(generation);try await adapter.install(manifest,files:files,userId:userId);try current(generation);onInstalled?()
        for part in manifest.parts { try? FileManager.default.removeItem(at:folder.appendingPathComponent(part.id.uuidString.lowercased())) }
    }
}
