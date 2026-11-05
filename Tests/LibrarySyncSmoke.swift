import Foundation

@main struct LibrarySyncSmoke {
    static let recordingID = UUID(uuidString:"da3592e7-1c03-4eb7-b98d-f1179d1b8bd1")!
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments[1], root = URL(fileURLWithPath:CommandLine.arguments[2])
        let server = URL(string:CommandLine.arguments[3])!
        var request = URLRequest(url:server.appendingPathComponent("v1/auth/account"));request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject:["username":"qa_sync_bridge","password":"synthetic-password"]);request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let (bytes,response) = try await URLSession.shared.data(for:request)
        precondition((response as! HTTPURLResponse).statusCode == 200)
        let token = (try JSONSerialization.jsonObject(with:bytes) as! [String:Any])["token"] as! String
        let client = LibrarySyncHTTP(server:server,token:token), identity = try await client.identity()
        // Exercise the actual AppState projection callback without credentials or microphones.
        let editorLibrary = try MeetingLibrary(root:root.appendingPathComponent("editor-qa"))
        var edit = try editorLibrary.save(MeetingRecord(title:"原题",text:"原文"))
        let editor = AppState(storageURL:editorLibrary.root,connectionNamespace:"sync-editor-qa-")
        editor.select(edit.id,saveCurrent:false)
        edit.title = "同步后的标题";edit.text = "同步后的文字";_ = try editorLibrary.save(edit)
        editor.reloadSyncProjection();precondition(editor.title == edit.title && editor.text == edit.text,"clean editor must display incoming text")
        editor.title = "尚未自动保存的标题";editor.text = "尚未自动保存的输入"
        let audioDir = editorLibrary.directory(for:edit.id).appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at:audioDir,withIntermediateDirectories:true)
        let original = audioDir.appendingPathComponent("received.wav");try Data("synthetic managed original".utf8).write(to:original)
        edit.audioFiles = [original.lastPathComponent];edit.audioDurations = [original.lastPathComponent:1];_ = try editorLibrary.save(edit)
        editor.libraryAudioSync?.onInstalled?()
        precondition(editor.title == "尚未自动保存的标题" && editor.text == "尚未自动保存的输入","audio refresh must preserve unsaved editor input")
        precondition(editor.saveEdits())
        let savedEdit = try editorLibrary.load(edit.id);precondition(savedEdit.audioFiles == edit.audioFiles && savedEdit.text == editor.text)
        editorLibrary.activeSyncUserId = identity.userId
        let flush = MacLibrarySyncAdapter(library:editorLibrary)
        flush.beforeRead = { precondition(editor.saveEdits()) }
        editor.text = "同步读取前立即保存"
        _ = try flush.values(userId:identity.userId)
        let flushed = try editorLibrary.load(edit.id);precondition(flushed.text == editor.text)
        print("PASS MAC EDITOR: clean incoming text displayed, unsaved input survives audio refresh, before-read flush persists input with new audio references")
        let library = try MeetingLibrary(root:root)
        let adapter = MacLibrarySyncAdapter(library:library)
        let engine = LibrarySyncEngine(root:root.appendingPathComponent("Sync"),adapter:adapter)
        try engine.connect(userId:identity.userId,server:server,transport:client,polling:false)
        if mode == "seed" {
            let unselected = try library.save(MeetingRecord(title:"未选择的本地定稿",text:"未选择的正文不得上传"))
            var live = MeetingRecord(title:"录音中字幕",text:"临时正文不得上传",status:.recording,previewText:"临时字幕不得上传")
            live = try library.save(live)
            engine.enable(recordingIds:[live.id]);let rejected = try library.load(live.id);precondition(rejected.userId == nil)
            engine.enable(recordingIds:[]);await engine.synchronize()
            let initial = try await client.changes(cursor:nil);precondition(initial.events.isEmpty)
            var catalog = try library.organization();let localGroup = RecordingCollection(name:"项目资料")
            catalog.groups.append(localGroup);try library.saveOrganization(catalog)
            var local = MeetingRecord(id:recordingID,title:"Mac 初始标题",text:"Mac 初始正式文字",duration:1.2)
            local.groupID = localGroup.id;local.previewText = "临时字幕不得上传";local.legacyLiveText = "临时实时文字不得上传"
            _ = try library.save(local)
            engine.enable(recordingIds:[local.id]);await engine.synchronize()
            var record = try library.load(recordingID);precondition(record.transcriptOrigin == .local && record.userId == identity.userId)
            let page = try await client.changes(cursor:nil),formal = page.events.last { $0.id == recordingID }!.value!.recording!
            precondition(formal.formalOrigin == .local && formal.text == local.text)
            let encodedPage = try JSONEncoder().encode(page);precondition(!String(decoding:encodedPage,as:UTF8.self).contains("临时"))
            let untouched = try library.load(unselected.id);precondition(untouched.userId == nil)
            var active = record;active.status = .recording;active.text = "续录中的临时正文不得上传";_ = try library.save(active)
            engine.localDidChange();await engine.synchronize()
            let during = try await client.changes(cursor:nil);precondition(during.events.last { $0.id == recordingID }?.value?.recording?.text == formal.text)
            do { try adapter.apply(LibrarySyncEntity(kind:.recording,id:recordingID,version:2,value:.recording(formal)),userId:identity.userId);preconditionFailure("incoming projection touched an active recording") } catch {}
            let protected = try library.load(recordingID);precondition(protected.status == .recording)
            _ = try library.save(record)
            record.title = "Mac 初始标题";record.text = "Mac 初始正式文字";_ = try library.save(record)
            engine.localDidChange();await engine.synchronize()
            precondition(engine.pendingCount == 0 && engine.conflicts.isEmpty,engine.message)
            var offline = try library.load(record.id);offline.title = "Mac 离线改稿";offline.text = "Mac 离线保留的正式文字"
            _ = try library.save(offline);engine.localDidChange()
            precondition(engine.pendingCount == 1)
            print("PASS MAC-SEED: selected local final uploaded, unselected final/live captions excluded, active capture uses final snapshot, offline outbox saved; no audio uploaded")
        } else {
            precondition(engine.pendingCount == 1,"offline queue must survive process restart")
            await engine.synchronize()
            precondition(engine.conflicts.count == 1,engine.message)
            let record = try library.load(recordingID)
            precondition(record.title == "Mac 离线改稿" && record.text == "Mac 离线保留的正式文字")
            precondition(engine.conflicts[0].remote?.value?.recording?.title == "iPhone 修改标题")
            let groups = try library.organization().groups
            precondition(groups.contains { $0.name == "项目·手机" })
            engine.resolve(engine.conflicts[0].id,useLocal:true);await engine.synchronize()
            precondition(engine.conflicts.isEmpty && engine.pendingCount == 0,engine.message)
            let oldOwner = identity.userId
            engine.disconnect();let hidden = try library.list();precondition(!hidden.contains { $0.id == recordingID })
            precondition((try? library.load(recordingID)) == nil,"signed-out Agent/native reads must not see account cache")
            let agent = AgentReadStore(root:root.appendingPathComponent("AgentData"))
            let exported = try agent.list();precondition(!exported.contains { $0.id == recordingID },"signed-out Agent export must hide the previous account")
            try engine.connect(userId:oldOwner,server:server,transport:client,polling:false);await engine.synchronize()
            let restored = try library.load(recordingID);precondition(restored.title == "Mac 离线改稿")
            print("PASS MAC-CONFLICT: restarted offline edit preserved against iPhone edit, conflict inspected/resolved, group rename received, signed-out cache hidden")
        }
    }
}
