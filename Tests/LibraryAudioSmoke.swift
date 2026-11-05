import Foundation
import AVFoundation

final class LostAudioReply: LibraryAudioTransport {
    let http: LibraryAudioHTTP;var lost = false;var uploaded = 0
    init(_ http: LibraryAudioHTTP) { self.http = http }
    func available(userId: UUID) async throws -> Bool { try await http.available(userId:userId) }
    func manifest(_ id: UUID) async throws -> LibraryAudioManifest? { try await http.manifest(id) }
    func start(_ p: LibraryAudioPart) async throws -> LibraryAudioUpload { try await http.start(p) }
    func upload(_ p: LibraryAudioPart,index: Int,bytes: Data) async throws { try await http.upload(p,index:index,bytes:bytes);uploaded += 1;if !lost { lost = true;throw URLError(.networkConnectionLost) } }
    func seal(_ p: LibraryAudioPart) async throws { try await http.seal(p) }
    func publish(_ id: UUID,base: Int,parts: [LibraryAudioPart]) async throws -> LibraryAudioManifest { try await http.publish(id,base:base,parts:parts) }
    func download(_ p: LibraryAudioPart,index: Int) async throws -> Data { try await http.download(p,index:index) }
}
@main struct LibraryAudioSmoke {
    static let id = UUID(uuidString:"35259fb8-c0f8-42db-a89b-0d8416ef22a8")!
    static func wave(_ url: URL, seconds: Double, hz: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        let output = try AVAudioFile(forWriting:url,settings:format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!
        var offset = 0;let count = Int(seconds*16000)
        while offset < count {
            buffer.frameLength = AVAudioFrameCount(min(16000,count-offset))
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(offset+i)*2*Double.pi*hz/16000)*0.1) }
            try output.write(from:buffer);offset += Int(buffer.frameLength)
        }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[2]),server = URL(string:CommandLine.arguments[3])!,mode = CommandLine.arguments[1]
        var r = URLRequest(url:server.appendingPathComponent("v1/auth/account"));r.httpMethod = "POST";r.setValue("application/json",forHTTPHeaderField:"Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject:["username":"qa_audio_bridge","password":"synthetic-password"])
        let (data,response) = try await URLSession.shared.data(for:r);precondition((response as! HTTPURLResponse).statusCode == 200)
        let token = (try JSONSerialization.jsonObject(with:data) as! [String:Any])["token"] as! String
        let text = LibrarySyncHTTP(server:server,token:token),identity = try await text.identity(),http = LibraryAudioHTTP(server:server,token:token)
        let library = try MeetingLibrary(root:root);library.activeSyncUserId = identity.userId
        let systemTemp = FileManager.default.temporaryDirectory.appendingPathComponent("talktuck-system-alias-"+UUID().uuidString)
        try LibraryAudioFiles.directory(systemTemp)
        defer { try? FileManager.default.removeItem(at:systemTemp) }
        let link = systemTemp.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        do { try LibraryAudioFiles.directory(link.appendingPathComponent("must-not-create"));preconditionFailure("managed symlink was followed") } catch {}
        precondition(!FileManager.default.fileExists(atPath:root.appendingPathComponent("must-not-create").path))
        if mode == "seed" {
            let formal = LibrarySyncRecording(id:id,title:"合成续录原音",createdAt:LibrarySyncCodec.date(Date()),durationMs:36250,source:"macos",language:"zh",isStarred:false,groupId:nil,speakers:[],paragraphs:[LibrarySyncParagraph(id:UUID(),text:"原音同步测试的正式稿",separator:"",startMs:35200,endMs:36000,speakerIds:[])])
            _ = try await text.mutate(deviceId:UUID(),mutation:LibrarySyncMutation(kind:.recording,id:id,baseVersion:0,value:.recording(formal)))
            try MacLibrarySyncAdapter(library:library).apply(LibrarySyncEntity(kind:.recording,id:id,version:1,value:.recording(formal)),userId:identity.userId)
            var record = try library.load(id)
            let dir = library.directory(for:id).appendingPathComponent("Audio");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            try wave(dir.appendingPathComponent("first.wav"),seconds:35,hz:440);try wave(dir.appendingPathComponent("continued.wav"),seconds:1.25,hz:660)
            record.audioFiles = ["first.wav","continued.wav"];record.audioDurations = ["first.wav":35,"continued.wav":1.25];_ = try library.save(record)
            let lost = LostAudioReply(http),adapter = MacLibraryAudioAdapter(library:library)
            let first = LibraryAudioSyncEngine(root:root.appendingPathComponent("Sync"),adapter:adapter)
            try first.connect(userId:identity.userId,server:server,transport:lost);await first.enqueue(id,direction:.upload)
            precondition(first.jobs.count == 1 && lost.uploaded == 1);first.disconnect()
            let second = LibraryAudioSyncEngine(root:root.appendingPathComponent("Sync"),adapter:adapter)
            try second.connect(userId:identity.userId,server:server,transport:http);precondition(second.jobs.count == 1);await second.retry();precondition(second.jobs.isEmpty,second.message+" "+String(describing:second.lastFailure))
            let manifest = try await http.manifest(id)!;precondition(manifest.parts.count == 2 && manifest.parts[0].byteLength > LibraryAudioFiles.chunkSize)
            print("PASS MAC AUDIO: >2 MiB split upload, response lost after server write, durable restart/resume, two continuation originals published; local formal text unchanged")
        } else {
            let cloud = try await http.manifest(id)!;precondition(cloud.parts.count == 1,"iPhone fixture should replace with its original")
            let adapter = MacLibraryAudioAdapter(library:library),audio = LibraryAudioSyncEngine(root:root.appendingPathComponent("Sync"),adapter:adapter)
            try audio.connect(userId:identity.userId,server:server,transport:http)
            await audio.enqueue(id,direction:.upload);precondition(audio.conflict != nil && audio.jobs.count == 1)
            await audio.retry();precondition(audio.conflict != nil);let unchanged = try await http.manifest(id);precondition(unchanged == cloud,"Retry must never bypass conflict choice")
            audio.remove(audio.jobs[0].id);await audio.enqueue(id,direction:.download);precondition(audio.jobs.isEmpty,audio.message)
            let record = try library.load(id),urls = try library.audioURLs(for:record)
            precondition(urls.count == 1);let (sha,n) = try LibraryAudioFiles.digest(urls[0]);precondition(sha == cloud.parts[0].sha256 && n == cloud.parts[0].byteLength)
            for file in ["first.wav","continued.wav"] { precondition(FileManager.default.fileExists(atPath:library.directory(for:id).appendingPathComponent("Audio").appendingPathComponent(file).path)) }
            precondition(record.text == "原音同步测试的正式稿")
            var pending = record;pending.status = .recorded;pending.pendingAudioFiles = record.audioFiles;_ = try library.save(pending)
            do { try await adapter.install(cloud,files:urls,userId:identity.userId);preconditionFailure("download replaced a pending local recording") } catch {}
            let protected = try library.load(id);precondition(protected.pendingAudioFiles == record.audioFiles)
            _ = try library.save(record)
            library.activeSyncUserId = UUID();do { _ = try await adapter.sources(id,userId:library.activeSyncUserId!);preconditionFailure("foreign audio exposed") } catch {}
            print("PASS MAC AUDIO: iPhone original downloaded and hash matched, previous continuation files retained, repeated retry cannot bypass conflict choice, foreign namespace rejected")
        }
    }
}
