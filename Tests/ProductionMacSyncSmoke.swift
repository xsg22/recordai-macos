import Foundation
import AVFoundation

@main struct ProductionMacSyncSmoke {
    struct Fixture: Codable { var runId: String;var server: URL;var username: String;var password: String;var macRecordingId: UUID;var phoneRecordingId: UUID;var groupId: UUID;var purpose: String;var expiresAt: Double }
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments[1],root = URL(fileURLWithPath:CommandLine.arguments[2])
        let f = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:root.appendingPathComponent("private/credentials.json")))
        guard f.purpose == "user-authorized-physical-device-sync-acceptance",f.expiresAt > Date().timeIntervalSince1970,f.username.hasPrefix("qa_sync_"),f.server.absoluteString == "https://xueshengguo.com/recordai" else { throw LibrarySyncError.invalidData }
        var request = URLRequest(url:f.server.appendingPathComponent("v1/auth/account"));request.httpMethod = "POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["username":f.username,"password":f.password])
        let (data,response) = try await URLSession.shared.data(for:request);guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LibrarySyncError.unavailable }
        let token = (try JSONSerialization.jsonObject(with:data) as! [String:Any])["token"] as! String
        let http = LibrarySyncHTTP(server:f.server,token:token),owner = try await http.identity().userId
        let library = try MeetingLibrary(root:root.appendingPathComponent("native-mac-library")),adapter = MacLibrarySyncAdapter(library:library)
        let sync = LibrarySyncEngine(root:library.root.appendingPathComponent("Sync"),adapter:adapter)
        try sync.connect(userId:owner,server:f.server,transport:http,polling:false)
        let audioHTTP = LibraryAudioHTTP(server:f.server,token:token),audio = LibraryAudioSyncEngine(root:library.root.appendingPathComponent("Sync"),adapter:MacLibraryAudioAdapter(library:library))
        try audio.connect(userId:owner,server:f.server,transport:audioHTTP)
        defer { sync.disconnect();audio.disconnect() }
        if mode == "seed" {
            let source = root.appendingPathComponent("mac-speech.wav"),before = try LibraryAudioFiles.digest(source)
            let model = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("CoHearTranscribe/Models/ASR/Qwen3ASR")
            let runtime = URL(fileURLWithPath:"/Applications/TalkTuck.app/Contents/Resources/Engine/ASR/qwen-asr")
            let began = Date(),result = try await Task.detached { try TranscriptionEngine().transcribe(audio:source,model:model,executable:runtime,language:"zh") }.value
            precondition(!result.text.isEmpty && result.text.range(of:"[\\p{Han}]",options:.regularExpression) != nil,"Actual local decoder must produce Chinese text")
            let after = try LibraryAudioFiles.digest(source);precondition(after.0 == before.0)
            var record = MeetingRecord(id:f.macRecordingId,title:"真机验收 · Mac 本地定稿",text:result.text,subtitles:result.subtitles,language:"zh",seconds:Date().timeIntervalSince(began))
            let duration = try await AVURLAsset(url:source).load(.duration)
            let managed = try library.importAudio(source,into:&record,recordingDuration:duration.seconds)
            record.status = .completed;record.pendingAudioFiles = [];record.transcriptOrigin = .local
            record.transcriptParagraphs = result.paragraphs.map { p in var row = p;row.audioFile = managed.lastPathComponent;row.localStart = row.start;return row }
            var organization = try library.organization();let group = RecordingCollection(id:f.groupId,name:"真机验收 · Mac 分组")
            organization.groups.append(group);try library.saveOrganization(organization);record.groupID = group.id
            record.previewText = "不能同步的临时字幕";_ = try library.save(record)
            sync.enable(recordingIds:[record.id]);await sync.synchronize()
            precondition(sync.pendingCount == 0 && sync.conflicts.isEmpty,sync.message)
            await audio.enqueue(record.id,direction:.upload);precondition(audio.jobs.isEmpty,audio.message+" "+String(describing:audio.lastFailure))
            let manifest = try await audioHTTP.manifest(record.id)!;precondition(manifest.parts.count == 1 && manifest.parts[0].sha256 == before.0)
            let page = try await http.changes(cursor:nil),encoded = try JSONEncoder().encode(page);precondition(!String(decoding:encoded,as:UTF8.self).contains("不能同步的临时字幕"))
            let report: [String:Any] = ["result":"PASS","realLocalInference":true,"userId":owner.uuidString,"text":result.text,"paragraphs":result.paragraphs.count,"recordingId":record.id.uuidString,"originalSHA256":before.0,"originalBytes":before.1,"durationSeconds":duration.seconds,"processingSeconds":Date().timeIntervalSince(began),"origin":"local"]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("mac-seed-report.json"))
            print("PASS: installed Mac decoder produced local final; actual native library enrolled and uploaded final/group/original over public HTTPS")
        } else {
            await sync.synchronize();precondition(sync.pendingCount == 0 && sync.conflicts.isEmpty,sync.message)
            let mac = try library.load(f.macRecordingId);precondition(mac.title == "真机验收 · SingleiPhone 校对 Mac 定稿" && mac.text.contains("SingleiPhone 校对"))
            var phone = try library.load(f.phoneRecordingId);precondition(phone.transcriptOrigin == .local && !phone.text.isEmpty)
            let groupId = phone.groupID!,group = try library.organization().group(groupId)!;precondition(group.name == "真机验收 · 手机整理")
            await audio.enqueue(phone.id,direction:.download);precondition(audio.jobs.isEmpty,audio.message+" "+String(describing:audio.lastFailure))
            phone = try library.load(phone.id);let downloaded = try library.audioURLs(for:phone);precondition(downloaded.count == 1)
            let checked = try LibraryAudioFiles.digest(downloaded[0]),manifest = try await audioHTTP.manifest(phone.id)!
            precondition(checked.0 == manifest.parts[0].sha256 && checked.1 == manifest.parts[0].byteLength)
            let playable = try AVAudioFile(forReading:downloaded[0]);precondition(playable.length > 0)
            let ids = phone.transcriptParagraphs.map(\.id)
            phone.title = "真机验收 · Mac 校对手机定稿";phone.transcriptParagraphs[0].text += "（Mac 回写确认）";phone.text = phone.transcriptParagraphs.map { $0.separator+$0.text }.joined()
            _ = try library.save(phone)
            var organization = try library.organization();let i = organization.groups.firstIndex { $0.id == groupId }!;organization.groups[i].name = "真机验收 · Mac 最终分组";try library.saveOrganization(organization)
            sync.localDidChange();await sync.synchronize();precondition(sync.pendingCount == 0 && sync.conflicts.isEmpty,sync.message)
            let saved = try library.load(phone.id);precondition(saved.transcriptParagraphs.map(\.id) == ids)
            let report: [String:Any] = ["result":"PASS","macTitle":mac.title,"macText":mac.text,"phoneTitle":phone.title,"phoneText":phone.text,"phoneOriginalSHA256":checked.0,"phoneOriginalBytes":checked.1,"phoneParagraphIDs":ids.map(\.uuidString),"group":"真机验收 · Mac 最终分组","localOriginRetained":true]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("mac-verify-report.json"))
            print("PASS: SingleiPhone text/group/original received natively on Mac; exact original hash/decoding and local provenance checked; final edit/group sent back")
        }
    }
}
