import Foundation

struct ProgressiveJob: Codable, Equatable, Sendable {
    var id = UUID()
    var start: Int64
    var ownedStart: Int64
    var end: Int64
    var status = "queued"
    var forcedBoundary = false
    var hasVoice = false
}
struct ProgressiveSnapshot: Sendable {
    let captureID: UUID
    let completedFrames: Int64
    let totalFrames: Int64
    let jobs: Int
    let text: String
    let subtitles: String
    let paragraphs: [TranscriptParagraph]
    var pendingSeams:Int = 0
}

/// Audio remains in the recorder's immutable AAC segments. This object queues
/// only range descriptors and text checkpoints; it holds no PCM audio buffer.
final class ProgressiveTranscriptionSession: @unchecked Sendable {
    typealias Processor = @Sendable (ProgressiveJob,URL) throws -> TranscriptionOutput
    private struct Journal: Codable {
        var version=1
        var captureID: UUID
        var language: String
        var baseOffset: Double
        var jobs: [ProgressiveJob]=[]
        var observed: Int64=0
        var sealed=false
    }
    private let queue=DispatchQueue(label:"com.xsg.talktuck.progressive-index",qos:.utility)
    private let worker=DispatchQueue(label:"com.xsg.talktuck.progressive-work",qos:.utility)
    private let model:URL,executable:URL,language:String,hotwords:[String],context:String
    private let baseOffset:Double,window:Int64
    private let onUpdate:@Sendable(ProgressiveSnapshot)->Void
    private let onFailure:@Sendable(String)->Void
    private let processor:Processor?
    private let initialBaseRecord:MeetingRecord?
    private var root:URL?,journal:Journal?
    private var quietSince:Int64?,lastQuiet:Int64=0,inputStart:Int64=0,ownedStart:Int64=0
    private var running=false,cancelled=false,currentEngine:TranscriptionEngine?
    private var cancellationRequested=false
    private var outputs:[UUID:TranscriptionOutput]=[:]
    private var waiters:[CheckedContinuation<ProgressiveSnapshot,Error>]=[]
    private var failures=Set<UUID>()
    private var analysisReady=Set<UUID>()
    private var voiceFrames:Int64=0
    private var stopWaiters:[CheckedContinuation<Void,Never>]=[]
    private let stateLock=NSLock()

    init(model:URL,executable:URL,language:String,hotwords:[String],context:String,baseOffset:Double,
         baseRecord:MeetingRecord?=nil,windowSeconds:Int?=nil,processor:Processor?=nil,onUpdate:@escaping @Sendable(ProgressiveSnapshot)->Void,onFailure:@escaping @Sendable(String)->Void) {
        self.model=model;self.executable=executable;self.language=language;self.hotwords=hotwords;self.context=context;self.baseOffset=baseOffset
        self.window=Int64(windowSeconds ?? ASRWindowPolicy.load(language:language).offlineSeconds)*16000
        self.onUpdate=onUpdate;self.onFailure=onFailure
        self.processor=processor;self.initialBaseRecord=baseRecord
    }
    func bindCanonicalArchive(_ capture:URL) throws {
        try queue.sync {
            guard let id=UUID(uuidString:capture.lastPathComponent),capture.deletingLastPathComponent().lastPathComponent=="Capture",
                  capture.resolvingSymlinksInPath().path==capture.standardizedFileURL.path,window>3*16000,window<=480*16000 else { throw BalancedAudioError.invalidManifest }
            root=capture.deletingLastPathComponent().appendingPathComponent("Progressive").appendingPathComponent(id.uuidString)
            guard root!.resolvingSymlinksInPath().path==root!.path else { throw BalancedAudioError.invalidManifest }
            try FileManager.default.createDirectory(at:root!,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let saved=root!.appendingPathComponent("progress.json")
            if FileManager.default.fileExists(atPath:saved.path) {
                guard saved.resolvingSymlinksInPath()==saved,
                      let size=try saved.resourceValues(forKeys:[.fileSizeKey]).fileSize,size>0,size<=16*1024*1024 else { throw BalancedAudioError.invalidManifest }
                let value=try JSONDecoder().decode(Journal.self,from:Data(contentsOf:saved))
                guard value.version==1,value.captureID==id,value.language==language,value.baseOffset==baseOffset,
                      value.observed>=0,value.observed<=7*24*3600*16000,value.jobs.count<=100000,
                      Set(value.jobs.map(\.id)).count==value.jobs.count else { throw BalancedAudioError.invalidManifest }
                var previous:Int64=0
                for job in value.jobs {
                    guard job.ownedStart==previous,job.start>=0,job.start<=job.ownedStart,
                          job.ownedStart-job.start<=3*16000,job.end>job.ownedStart,
                          job.end-job.start<=window,job.end<=value.observed else { throw BalancedAudioError.invalidManifest }
                    previous=job.end
                }
                journal=value
                for job in value.jobs {
                    if let data=try? Data(contentsOf:resultURL(job)),let result=try? JSONDecoder().decode(TranscriptionOutput.self,from:data) { outputs[job.id]=result }
                }
                for i in journal!.jobs.indices { journal!.jobs[i].status=outputs[journal!.jobs[i].id] == nil ? "queued":"completed" }
                for (i,job) in value.jobs.enumerated() where outputs[job.id]==nil {
                    if let key=try? ProgressiveAnalysisCache.key(job:job,root:root!,previous:i>0 ? value.jobs[i-1]:nil,model:model,language:language),
                       ProgressiveAnalysisCache.valid(ProgressiveAnalysisCache.directory(root:root!,job:job),key:key) {
                        try ProgressiveAnalysisCache.publishVoice(from:ProgressiveAnalysisCache.directory(root:root!,job:job),root:root!,job:job)
                        analysisReady.insert(job.id)
                    }
                }
                ownedStart=value.jobs.last?.end ?? 0
                inputStart=ownedStart-(value.jobs.last?.forcedBoundary == true ? 3*16000:0)
            } else { journal=Journal(captureID:id,language:language,baseOffset:baseOffset) }
            if let initialBaseRecord {
                let base=root!.appendingPathComponent("base-record.json")
                if !FileManager.default.fileExists(atPath:base.path) { try BalancedAudioIO.save(initialBaseRecord,to:base) }
            }
            try persist()
        }
    }
    func saveBaseRecord(_ record:MeetingRecord) throws {
        try queue.sync {
            guard let root else { throw BalancedAudioError.invalidManifest }
            let url=root.appendingPathComponent("base-record.json")
            if !FileManager.default.fileExists(atPath:url.path) { try BalancedAudioIO.save(record,to:url) }
        }
    }
    static func baseRecord(capture:URL) throws -> MeetingRecord {
        let url=capture.deletingLastPathComponent().appendingPathComponent("Progressive").appendingPathComponent(capture.lastPathComponent).appendingPathComponent("base-record.json")
        return try JSONDecoder().decode(MeetingRecord.self,from:Data(contentsOf:url))
    }
    func currentSnapshot() -> ProgressiveSnapshot? { queue.sync { journal == nil ? nil:snapshot() } }
    func append(_ samples:[Float],at offset:Double) {
        guard !samples.isEmpty,offset.isFinite,offset>=0 else { return }
        let end=Int64((offset*16000).rounded())+Int64(samples.count)
        let frameCount=Int64(samples.count)
        let quiet=samples.reduce(Float(0)){$0+$1*$1}/Float(samples.count)<0.000001
        observe(endFrame:end,frameCount:frameCount,quiet:quiet)
    }
    func observe(endFrame end:Int64,frameCount:Int64,quiet:Bool) {
        guard end>=0,frameCount>0,end>=frameCount else { return }
        // Only scalar metadata is retained by this queue, never samples.
        queue.async { [self] in
            guard !cancelled,journal != nil,journal!.sealed == false else { return }
            journal!.observed=max(journal!.observed,end)
            if !quiet { voiceFrames+=frameCount }
            if quiet {
                if quietSince==nil { quietSince=end-frameCount }
                if end-(quietSince ?? end)>=6400 { lastQuiet=end }
            } else { quietSince=nil }
            do { try closeReady();kick() } catch { onFailure(error.localizedDescription) }
        }
    }
    private func closeReady() throws {
        while let observed=journal?.observed,observed-inputStart>=window {
            let limit=inputStart+window
            let cut=lastQuiet>=max(ownedStart+1,limit-30*16000) && lastQuiet<=limit ? lastQuiet:limit
            try close(at:cut,forced:cut==limit && (quietSince==nil || limit-(quietSince ?? limit)<6400))
        }
    }
    private func close(at end:Int64,forced:Bool) throws {
        guard end>ownedStart,let root,let id=journal?.captureID else { return }
        let job=ProgressiveJob(start:inputStart,ownedStart:ownedStart,end:end,forcedBoundary:forced,hasVoice:voiceFrames>8000)
        let ref=CanonicalAudioRange(sourceRecordingID:id,startFrame:job.start,endFrame:end)
        try BalancedAudioIO.save(ref,to:root.appendingPathComponent(job.id.uuidString+".json"))
        journal!.jobs.append(job);ownedStart=end;inputStart=max(0,end-(forced ? 3*16000:0));lastQuiet=0
        voiceFrames=0
        try persist()
    }
    func finish(totalFrames:Int64) async throws -> ProgressiveSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard journal != nil,!cancelled,totalFrames>=ownedStart else { throw BalancedAudioError.invalidManifest }
                    journal!.observed=totalFrames;try closeReady()
                    if totalFrames>ownedStart { try close(at:totalFrames,forced:false) }
                    journal!.sealed=true;failures=[];try persist();waiters.append(continuation);kick();resolve()
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func cancel() {
        stateLock.lock();cancellationRequested=true;currentEngine?.cancel();stateLock.unlock()
        queue.async { [self] in cancelled=true;for w in waiters { w.resume(throwing:CancellationError()) };waiters=[] }
    }
    func cancelAndWait() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async { [self] in if running { stopWaiters.append(continuation) } else { continuation.resume() } }
        }
    }
    private func persist() throws { if let root,let journal { try BalancedAudioIO.save(journal,to:root.appendingPathComponent("progress.json")) } }
    private func resultURL(_ job:ProgressiveJob)->URL { root!.appendingPathComponent(job.id.uuidString+"-result.json") }
    func acceptsBody(_ text:String)->Bool {
        queue.sync {
            guard let journal else { return false }
            if text.isEmpty { return true }
            for count in 1...max(1,journal.jobs.count) {
                if snapshot(limit:count).text==text { return true }
            }
            return false
        }
    }
    private func snapshot(limit:Int?=nil) -> ProgressiveSnapshot {
        var text="";var subtitles="";var rows:[TranscriptParagraph]=[];var completed:Int64=0
        func stamp(_ t:Double)->String { let m=Int((t*1000).rounded());return String(format:"%02d:%02d:%02d,%03d",m/3600000,m/60000%60,m/1000%60,m%1000) }
        for job in journal!.jobs.prefix(limit ?? journal!.jobs.count) {
            guard let output=outputs[job.id] else { break }
            if !output.text.isEmpty { subtitles+="\(subtitles.components(separatedBy:"\n\n").filter{!$0.isEmpty}.count+1)\n\(stamp(baseOffset+Double(job.ownedStart)/16000)) --> \(stamp(baseOffset+Double(job.end)/16000))\n\(output.text)\n\n" }
            var first=true
            for var row in output.paragraphs {
                let boundary=first && !rows.isEmpty;first=false
                let local=row.start ?? row.alignedStart
                row.applyAudioOffset(baseOffset+Double(job.start)/16000)
                row.localStart=local.map{$0+Double(job.start)/16000}
                row.audioFile="progressive-"+journal!.captureID.uuidString
                row.speakerIDs=row.speakerIDs.map{"progressive-"+journal!.captureID.uuidString+":"+$0}
                if boundary,job.start<job.ownedStart,let previous=rows.last,let merged=Self.joinBoundary(previous,row) {
                    rows[rows.count-1]=merged
                } else {
                    if boundary { row.separator="\n"+row.separator }
                    rows.append(row)
                }
            }
            completed=job.end
        }
        text=rows.map{$0.separator+$0.text}.joined()
        return ProgressiveSnapshot(captureID:journal!.captureID,completedFrames:completed,totalFrames:journal!.observed,jobs:outputs.count,text:text,subtitles:subtitles,paragraphs:rows,pendingSeams:failures.count)
    }
    /// A transport edge is not a sentence boundary. Join only a confident,
    /// same-speaker unfinished sentence; never join an actual pause or change.
    static func joinBoundary(_ a:TranscriptParagraph,_ b:TranscriptParagraph)->TranscriptParagraph? {
        guard a.speakerIDs.count==1,a.speakerIDs==b.speakerIDs,a.audioFile==b.audioFile,
              let end=a.end ?? a.alignedEnd,let start=b.start ?? b.alignedStart,
              start>=end-0.15,start-end<=5,
              !SentencePolicy.boundaries(Array(a.text)).contains(a.text.count) else { return nil }
        let words=SentencePolicy.usesWords(a.text+b.text)
        let size=SentencePolicy.unitPrefix(Array(a.text+b.text),words:words).last ?? 0
        guard size<=(words ? SentencePolicy.rules.wordMaximum:SentencePolicy.rules.characterMaximum) else { return nil }
        var result=a
        var separator=b.separator
        if words,separator.isEmpty,a.text.last?.isWhitespace==false,b.text.first?.isLetter==true { separator=" " }
        result.text+=separator+b.text
        if a.start != nil,b.start != nil { result.end=b.end }
        else {
            result.alignedStart=a.alignedStart ?? a.start;result.alignedEnd=b.alignedEnd ?? b.end
            result.start=nil;result.end=nil
        }
        return result
    }
    static func recoveryWindow(configured:Int,failed:Int?)->Int {
        guard let failed,[480,360,120,60,24].contains(failed) else { return configured }
        return min(configured,failed>120 ? 120:failed>60 ? 60:24)
    }
    private func kick() {
        guard !running,!cancelled,let root,let journal else { return }
        // A failed ownership check does not invalidate the advanced voice
        // checkpoint. Continue serial analysis of later ranges while keeping
        // their results private behind the unacknowledged seam.
        guard let index=journal.jobs.indices.first(where:{ i in
            let job=journal.jobs[i]
            return outputs[job.id]==nil && !failures.contains(job.id) &&
                (processor != nil || i==0 || outputs[journal.jobs[i-1].id] != nil || analysisReady.contains(journal.jobs[i-1].id))
        }) else { resolve();return }
        let job=journal.jobs[index]
        running=true
        let previous=index>0 ? journal.jobs[index-1]:nil
        let priorText:String
        let prefix=snapshot(limit:index)
        if let previous,prefix.completedFrames<previous.end,let output=outputs[previous.id] { priorText=output.text }
        else if let previous,outputs[previous.id]==nil,
           let data=try? Data(contentsOf:root.appendingPathComponent(previous.id.uuidString+"-asr.json")),let raw=try? JSONDecoder().decode(TranscriptionOutput.self,from:data) { priorText=raw.text }
        else { priorText=prefix.text }
        worker.async { [self] in
            do {
                let ref=root.appendingPathComponent(job.id.uuidString+".json")
                if let processor {
                    let result=try processor(job,ref)
                    try BalancedAudioIO.save(result,to:resultURL(job));completed(job,result:result);return
                }
                guard try CanonicalAudioInput.reader(for:ref) != nil else { throw CanonicalAudioInput.Failure.notReady }
                let attempt=root.appendingPathComponent("work-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:attempt,withIntermediateDirectories:false)
                let engine=TranscriptionEngine(temporaryRoot:attempt,evidenceRoot:attempt,memoryLimitMB:language=="yue" ? 3072:nil)
                stateLock.lock();currentEngine=engine;if cancellationRequested { engine.cancel() };stateLock.unlock()
                defer { stateLock.lock();currentEngine=nil;stateLock.unlock() }
                let recognition=root.appendingPathComponent(job.id.uuidString+"-asr.json")
                let raw:TranscriptionOutput
                if let data=try? Data(contentsOf:recognition),let cached=try? JSONDecoder().decode(TranscriptionOutput.self,from:data),
                   !cached.text.isEmpty || !job.hasVoice { raw=cached }
                else {
                    let recovery=root.appendingPathComponent(job.id.uuidString+"-window-recovery.json")
                    let savedFailure=(try? Data(contentsOf:recovery)).flatMap{try? JSONDecoder().decode([String:Int].self,from:$0)}?["failedWindowSeconds"]
                    let requested=Self.recoveryWindow(configured:Int(window/16000),failed:savedFailure)
                    raw=try engine.transcribeBatch(audio:ref,model:model,executable:executable,language:language,hotwords:hotwords,
                        context:context+String(priorText.suffix(1200)),windowSeconds:requested,onRecovery:{seconds in
                            try? BalancedAudioIO.save(["failedWindowSeconds":seconds],to:recovery)
                        })
                    try BalancedAudioIO.save(raw,to:recognition)
                }
                if raw.text.isEmpty && job.hasVoice { throw TranscriptionError.message("这一批有声音但尚未识别出文字，原音和检查点已保留，可重试。") }
                let state=attempt.appendingPathComponent("speaker.json")
                let key=try ProgressiveAnalysisCache.key(job:job,root:root,previous:previous,model:model,language:language)
                let analysis=ProgressiveAnalysisCache.directory(root:root,job:job)
                var cached=ProgressiveAnalysisCache.valid(analysis,key:key)
                if !cached,FileManager.default.fileExists(atPath:analysis.appendingPathComponent("ready.json").path) {
                    throw TranscriptionError.message("已有定稿候选检查点不一致，原音和候选已保留，未重新识别整批录音。")
                }
                if !cached { cached=try ProgressiveAnalysisCache.importLegacy(root:root,job:job,key:key,raw:raw,priorText:priorText,to:analysis) }
                if !cached,let previous {
                    for ext in ["json","safetensors"] {
                        let old=root.appendingPathComponent(previous.id.uuidString+"-speaker."+ext)
                        try FileManager.default.copyItem(at:old,to:state.deletingPathExtension().appendingPathExtension(ext))
                    }
                    var meta=try JSONSerialization.jsonObject(with:Data(contentsOf:state))as! [String:Any]
                    meta["skipSeconds"]=Double(job.ownedStart-job.start)/16000
                    try JSONSerialization.data(withJSONObject:meta).write(to:state,options:.atomic)
                }
                let result:TranscriptionOutput
                do {
                    if !cached {
                        _ = try engine.analyzeSpeakers(audio:ref,model:model,executable:executable,transcript:raw,language:language,hotwords:hotwords,speakerCheckpoint:state)
                        if !raw.text.isEmpty {
                            guard ProgressiveAnalysisCache.matchesText(attempt,raw:raw) else { throw BalancedAudioError.invalidManifest }
                            try ProgressiveAnalysisCache.save(from:attempt,to:analysis,key:key);cached=true
                        }
                    }
                    if cached {
                        // Commit continuous voice evidence before trying the
                        // seam. This enables the following job after a failure.
                        try ProgressiveAnalysisCache.publishVoice(from:analysis,root:root,job:job)
                        queue.sync { _ = analysisReady.insert(job.id) }
                    }
                    if raw.text.isEmpty { result=raw }
                    else {
                        do { result=try engine.cropSpeakerEvidence(at:analysis,trimBefore:Double(job.ownedStart-job.start)/16000,previousText:priorText,executable:executable,hotwords:hotwords) }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            guard job.ownedStart>job.start,cached else { throw error }
                            result=try engine.repairProgressiveSeam(audio:ref,model:model,executable:executable,directory:analysis,trimBefore:Double(job.ownedStart-job.start)/16000,previousText:priorText,language:language,hotwords:hotwords)
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // Recognition is authoritative. If voice state advanced
                    // safely and this range has no overlap to disambiguate,
                    // optional alignment failure cannot erase the whole text.
                    guard job.start==job.ownedStart,
                          FileManager.default.fileExists(atPath:state.path),
                          FileManager.default.fileExists(atPath:state.deletingPathExtension().appendingPathExtension("safetensors").path) else { throw error }
                    result=raw.readingFallback(hotwords:hotwords)
                    try BalancedAudioIO.save(["message":error.localizedDescription],to:root.appendingPathComponent(job.id.uuidString+"-annotation-issue.json"))
                }
                // Commit result last. A crash before this marker reruns only
                // annotations using cached ASR, never the acknowledged prefix.
                if !cached { try ProgressiveAnalysisCache.publishVoice(from:attempt,root:root,job:job) }
                try BalancedAudioIO.save(result,to:resultURL(job))
                try? FileManager.default.removeItem(at:attempt)
                completed(job,result:result)
            } catch CanonicalAudioInput.Failure.notReady {
                queue.asyncAfter(deadline:.now()+1) { [self] in running=false;resolve();kick() }
            } catch {
                queue.async { [self] in
                    running=false;failures.insert(job.id)
                    let detail=["jobId":job.id.uuidString,"message":error.localizedDescription]
                    try? BalancedAudioIO.save(detail,to:root.appendingPathComponent("last-failure.json"))
                    if let i=self.journal!.jobs.firstIndex(where:{$0.id==job.id}) { self.journal!.jobs[i].status=analysisReady.contains(job.id) ? "seam-pending":"failed" }
                    try? persist();onFailure(error.localizedDescription);kick();resolve()
                }
            }
        }
    }
    private func completed(_ job:ProgressiveJob,result:TranscriptionOutput) {
        queue.async { [self] in
            outputs[job.id]=result;failures.remove(job.id);running=false
            if let i=self.journal!.jobs.firstIndex(where:{$0.id==job.id}) { self.journal!.jobs[i].status="completed" }
            try? persist();if !cancelled { onUpdate(snapshot()) };kick();resolve()
        }
    }
    private func resolve() {
        if !running { let stopped=stopWaiters;stopWaiters=[];for w in stopped { w.resume() } }
        guard !running,!waiters.isEmpty,let journal,journal.sealed else { return }
        let ready=snapshot()
        guard ready.completedFrames==journal.observed || !failures.isEmpty else { return }
        let current=waiters;waiters=[]
        for w in current {
            if ready.completedFrames==journal.observed { w.resume(returning:ready) }
            else { w.resume(throwing:TranscriptionError.message("录音已停止并保存。部分转录尚未完成，可继续转录；原音、已有定稿与重试位置均已保留。")) }
        }
    }
}

/// The same commit is used before and after stop; metadata belongs to the
/// latest saved record while text belongs to the acknowledged capture prefix.
enum ProgressiveTranscriptCommit {
    static func normalizedBase(_ input:MeetingRecord)->MeetingRecord {
        var record=input
        if !record.text.isEmpty && !record.hasCurrentParagraphs { record.transcriptParagraphs=[TranscriptParagraph(text:record.text)] }
        return record
    }
    static func apply(_ snapshot:ProgressiveSnapshot,base:MeetingRecord,expectedText:String,audioFile:String?,
                      complete:Bool,recording:Bool,tail:[TranscriptParagraph]=[],tailSubtitles:String="",to latest:inout MeetingRecord) throws {
        let prefix=base.text.isEmpty || snapshot.text.isEmpty ? "":"\n\n"
        var wanted=base.text+prefix+snapshot.text
        var following=tail
        if !following.isEmpty { following[0].separator=wanted.isEmpty ? "":"\n\n" }
        wanted+=following.map{$0.separator+$0.text}.joined()
        guard latest.id==base.id,latest.text==expectedText || latest.text==wanted else { throw TranscriptionError.message("正文已修改，后台定稿已另存，未覆盖人工编辑。") }
        var rows=snapshot.paragraphs
        if !rows.isEmpty { rows[0].separator=prefix+rows[0].separator }
        if let file=audioFile { for i in rows.indices { rows[i].audioFile=file } }
        let old=base.hasCurrentParagraphs ? base.transcriptParagraphs : (base.text.isEmpty ? []:[TranscriptParagraph(text:base.text)])
        latest.text=wanted;latest.transcriptParagraphs=old+rows+following
        latest.subtitles=try MeetingRecordingAppend.appendSRT(snapshot.subtitles,to:base.subtitles,offset:0)
        latest.subtitles=try MeetingRecordingAppend.appendSRT(tailSubtitles,to:latest.subtitles,offset:0)
        latest.duration=max(latest.duration,base.duration+Double(snapshot.totalFrames)/16000)
        latest.transcriptOrigin = .local;latest.transcriptionEngine="qwen3-asr-1.7b-8bit"
        for row in rows { for id in row.speakerIDs where latest.speakerNames[id]==nil { latest.speakerNames[id]="发言人 \(latest.speakerNames.count+1)" } }
        if complete {
            if let file=audioFile { latest.pendingAudioFiles.removeAll{$0==file} }
            latest.status=wanted.isEmpty ? .recorded:.completed
            latest.speakerAnalysisStatus=rows.contains{$0.start==nil || $0.speakerIDs.isEmpty} ? .partial:.completed
            latest.speakerAnalysisMessage=latest.speakerAnalysisStatus == .partial ? "部分文字时间待对齐，正文与已确认的发言人已保留。":"最多区分4位发言人；续录标签独立，可手动改名或合并。重叠与不确定片段请核对。"
        } else { latest.status=recording ? .recording:.recorded;latest.speakerAnalysisStatus = .processing }
    }
}

/// Rebase an unfinished capture around independently saved later captures.
/// Checkpoint publication and library save are separate atomic writes; any
/// acknowledged prefix (including an unpublished one) is safe to recover.
struct ProgressiveTranscriptRecovery {
    var base:MeetingRecord
    var tail:[TranscriptParagraph]=[]
    var tailSubtitles=""
    init(original:MeetingRecord,record:MeetingRecord,file:String,captureID:UUID,totalFrames:Int64,session:ProgressiveTranscriptionSession) throws {
        base=original
        guard let index=record.audioFiles.firstIndex(of:file) else { throw BalancedAudioError.invalidManifest }
        let later=Set(record.audioFiles.dropFirst(index+1)),placeholder="progressive-"+captureID.uuidString
        if record.hasCurrentParagraphs {
            let own=record.transcriptParagraphs.filter{$0.audioFile==file || $0.audioFile==placeholder}
            let before=record.transcriptParagraphs.filter{$0.audioFile != file && $0.audioFile != placeholder && !later.contains($0.audioFile ?? "")}
            tail=record.transcriptParagraphs.filter{later.contains($0.audioFile ?? "")}
            let body=own.enumerated().map{($0.offset==0 ? "":$0.element.separator)+$0.element.text}.joined()
            guard session.acceptsBody(body), (before+own+tail).map({$0.separator+$0.text}).joined()==record.text else { throw TranscriptionError.message("正文已修改，后台定稿已另存，未覆盖人工编辑。") }
            base.text=before.map{$0.separator+$0.text}.joined();base.transcriptParagraphs=before
            base.subtitles=try MeetingRecordingAppend.sliceSRT(record.subtitles,beforeEnd:base.duration)
            tailSubtitles=try MeetingRecordingAppend.sliceSRT(record.subtitles,afterStart:base.duration+Double(totalFrames)/16000)
        } else {
            let prefix=original.text.isEmpty ? "":original.text+"\n\n"
            let body=record.text==original.text ? "":record.text.hasPrefix(prefix) ? String(record.text.dropFirst(prefix.count)):record.text
            guard session.acceptsBody(body) else { throw TranscriptionError.message("正文已修改，后台定稿已另存，未覆盖人工编辑。") }
        }
    }
}
