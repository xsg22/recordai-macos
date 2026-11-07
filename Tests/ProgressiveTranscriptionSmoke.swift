import Foundation
import AVFoundation

private final class ProgressiveCalls: @unchecked Sendable {
    let lock=NSLock();var jobs:[ProgressiveJob]=[];var active=0;var maximum=0;var failed=false
    func run(_ job:ProgressiveJob,failSecond:Bool=false) throws -> TranscriptionOutput {
        lock.lock();active+=1;maximum=max(maximum,active);jobs.append(job)
        let fail=failSecond && jobs.count==2 && !failed
        if fail { failed=true };lock.unlock()
        defer { lock.lock();active-=1;lock.unlock() }
        if fail { throw NSError(domain:"fixture",code:1) }
        let text="range_\(job.ownedStart)_\(job.end)。"
        return TranscriptionOutput(text:text,subtitles:"",paragraphs:[TranscriptParagraph(text:text,start:Double(job.ownedStart-job.start)/16000,end:Double(job.end-job.start)/16000,speakerIDs:["0"])])
    }
    var all:[ProgressiveJob] { lock.lock();defer{lock.unlock()};return jobs }
}

@main struct ProgressiveTranscriptionSmoke {
    static func main() async throws {
        precondition(ProgressiveTranscriptionSession.recoveryWindow(configured:360,failed:360)==120)
        precondition(ProgressiveTranscriptionSession.recoveryWindow(configured:360,failed:120)==60)
        precondition(ProgressiveTranscriptionSession.recoveryWindow(configured:480,failed:nil)==480)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for (language,window,total)in [("zh",480,1100),("en",360,8*3600)] {
            let capture=root.appendingPathComponent(language).appendingPathComponent("Capture").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:capture,withIntermediateDirectories:true)
            let calls=ProgressiveCalls(),base=MeetingRecord(title:"Before hardware starts")
            let session=ProgressiveTranscriptionSession(model:root,executable:root,language:language,hotwords:[],context:"",baseOffset:7,baseRecord:base,windowSeconds:window,processor:{job,_ in try calls.run(job)},onUpdate:{_ in},onFailure:{_ in})
            try session.bindCanonicalArchive(capture)
            let persistedBase=try ProgressiveTranscriptionSession.baseRecord(capture:capture)
            precondition(persistedBase.id==base.id)
            for end in stride(from:10,through:total,by:10) { session.observe(endFrame:Int64(end)*16000,frameCount:160000,quiet:false) }
            let result=try await session.finish(totalFrames:Int64(total)*16000)
            let jobs=calls.all
            precondition(jobs.first?.start==0 && jobs.first?.end==Int64(window)*16000)
            precondition(jobs.reduce(Int64(0)){$0+$1.end-$1.ownedStart}==Int64(total)*16000,"Owned audio ranges must neither overlap nor leave holes")
            for pair in zip(jobs,jobs.dropFirst()) { precondition(pair.0.end==pair.1.ownedStart && pair.1.ownedStart-pair.1.start==48000) }
            precondition(jobs.allSatisfy{$0.end-$0.start<=Int64(window)*16000} && result.completedFrames==Int64(total)*16000)
            precondition(result.paragraphs.count==jobs.count && Set(result.paragraphs.flatMap(\.speakerIDs)).count==1,"Speaker namespace must belong to the capture, never to each batch")
            precondition(result.paragraphs[0].start==7 && result.paragraphs[0].localStart==0)
            let restoredCalls=ProgressiveCalls()
            let restored=ProgressiveTranscriptionSession(model:root,executable:root,language:language,hotwords:[],context:"",baseOffset:7,windowSeconds:window,processor:{job,_ in try restoredCalls.run(job)},onUpdate:{_ in},onFailure:{_ in})
            try restored.bindCanonicalArchive(capture)
            let after=try await restored.finish(totalFrames:Int64(total)*16000)
            precondition(restored.acceptsBody("") && restored.acceptsBody(result.paragraphs[0].text) && !restored.acceptsBody("manual edit"))
            precondition(after.text==result.text && after.paragraphs==result.paragraphs && restoredCalls.all.isEmpty,"Stopping/restarting cannot resend acknowledged batches")
            precondition(calls.maximum==1)
            let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.fileSizeKey])!.allObjects as! [URL]
            precondition(!files.contains{["wav","caf","m4a","pcm"].contains($0.pathExtension)},"The indexer must not spool a second full audio copy")
        }
        let calls=ProgressiveCalls(),capture=root.appendingPathComponent("retry/Capture/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:capture,withIntermediateDirectories:true)
        let retry=ProgressiveTranscriptionSession(model:root,executable:root,language:"zh",hotwords:[],context:"",baseOffset:0,windowSeconds:24,processor:{job,_ in try calls.run(job,failSecond:true)},onUpdate:{_ in},onFailure:{_ in})
        try retry.bindCanonicalArchive(capture)
        retry.observe(endFrame:50*16000,frameCount:50*16000,quiet:false)
        try await Task.sleep(nanoseconds:100_000_000)
        let final=try await retry.finish(totalFrames:50*16000)
        precondition(final.completedFrames==50*16000)
        let grouped=Dictionary(grouping:calls.all,by:{$0.id})
        precondition(grouped.values.filter{$0.count==2}.count==1 && grouped[calls.all[0].id]?.count==1,"Retry only the failed job, preserve acknowledged prefix")
        let a=TranscriptParagraph(text:"我",alignedStart:1,alignedEnd:1.2)
        var first=a;first.speakerIDs=["0"];first.audioFile="a"
        var next=TranscriptParagraph(text:"继续说完。",start:1.2,end:3,audioFile:"a",speakerIDs:["0"])
        precondition(ProgressiveTranscriptionSession.joinBoundary(first,next)?.text=="我继续说完。")
        next.speakerIDs=["1"];precondition(ProgressiveTranscriptionSession.joinBoundary(first,next)==nil)
        next.speakerIDs=["0"];next.start=6.201;precondition(ProgressiveTranscriptionSession.joinBoundary(first,next)==nil)
        // Save a progressive prefix before registering its single original.
        // Import uses an absolute timeline end so stop cannot double duration.
        let library=try MeetingLibrary(root:root.appendingPathComponent("CommitLibrary"))
        var base=MeetingRecord(title:"Base",text:"原文",duration:7,status:.recording)
        base=ProgressiveTranscriptCommit.normalizedBase(base)
        base=try library.save(base);var record=base
        var shifted=final.paragraphs
        for i in shifted.indices { let local=shifted[i].start;shifted[i].applyAudioOffset(7);shifted[i].localStart=local }
        let committed=ProgressiveSnapshot(captureID:final.captureID,completedFrames:final.completedFrames,totalFrames:final.totalFrames,jobs:final.jobs,text:final.text,subtitles:"",paragraphs:shifted)
        try ProgressiveTranscriptCommit.apply(committed,base:base,expectedText:base.text,audioFile:nil,complete:false,recording:true,to:&record)
        let expected=record.text;record.title="用户新标题"
        record=try library.save(record)
        let id=UUID(),directory=library.directory(for:record.id).appendingPathComponent("Capture/"+id.uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let sink=MeetingAudioSink(directory:directory,started:1000,canonicalRecordingID:id,onError:{_ in preconditionFailure("fixture capture failed")})
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        for second in 0..<50 {
            let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!;buffer.frameLength=16000
            buffer.floatChannelData![0].initialize(repeating:0.01,count:16000)
            sink.appendMicrophone(buffer,at:1000+Double(second))
            sink.setPaused(false,at:1001+Double(second))
        }
        let original=try sink.finishCanonical(duration:50)
        _=try library.importAudio(original,into:&record,recordingDuration:50,captureSession:id,timelineEnd:base.duration+50)
        let file=record.audioFiles.last!
        try ProgressiveTranscriptCommit.apply(committed,base:base,expectedText:expected,audioFile:file,complete:true,recording:false,to:&record)
        _=try library.save(record);let saved=try library.load(record.id)
        precondition(saved.duration==57 && saved.audioFiles.count==1 && saved.pendingAudioFiles.isEmpty && saved.title=="用户新标题")
        precondition(saved.hasCurrentParagraphs && saved.text==expected && saved.transcriptParagraphs.dropFirst().allSatisfy{$0.audioFile==file})
        let published=try AgentDataPublisher.snapshot(saved,libraryRoot:root.appendingPathComponent("CommitLibrary"))
        precondition(published.finalText==saved.text && saved.status == .completed)
        let later=TranscriptParagraph(text:"后续录音。",separator:"\n\n",start:60,end:61,audioFile:"later",speakerIDs:["later:0"])
        var extended=saved;extended.audioFiles.append("later");extended.audioDurations["later"]=4;extended.duration=61
        let tailSRT="1\n00:01:00,000 --> 00:01:01,000\n后续录音。\n\n"
        try ProgressiveTranscriptCommit.apply(committed,base:base,expectedText:extended.text,audioFile:file,complete:true,recording:false,tail:[later],tailSubtitles:tailSRT,to:&extended)
        let restored=try ProgressiveTranscriptRecovery(original:base,record:extended,file:file,captureID:final.captureID,totalFrames:50*16000,session:retry)
        precondition(restored.tail.map(\.id)==[later.id] && restored.base.text==base.text && restored.tailSubtitles.contains("后续录音。"))
        let beforeReapply=extended
        try ProgressiveTranscriptCommit.apply(committed,base:restored.base,expectedText:extended.text,audioFile:file,complete:true,recording:false,tail:restored.tail,tailSubtitles:restored.tailSubtitles,to:&extended)
        precondition(extended.text==beforeReapply.text && extended.transcriptParagraphs.map(\.id)==beforeReapply.transcriptParagraphs.map(\.id),"Recovering an earlier capture cannot overwrite or duplicate later captures")
        var edited=saved;edited.text="人工修改"
        do {try ProgressiveTranscriptCommit.apply(committed,base:base,expectedText:expected,audioFile:file,complete:true,recording:false,to:&edited);preconditionFailure("Must preserve human edit")}
        catch {precondition(edited.text=="人工修改")}
        print("PASS: zh480/en360, 8h accelerated range indexing without PCM copies, contiguous ownership, serial workers, stable speaker namespace/IDs, checkpoint reuse and failed-range-only retry")
    }
}
