import Foundation
import AVFoundation

/// Human source replay through the production audio sink and all ASR workers.
/// This does not exercise physical microphone/screen capture or battery power.
private final class ProgressiveProbe: @unchecked Sendable {
    let lock=NSLock(); var events:[[String:Any]]=[];var rows:[LiveUtterance]=[];var pending:[LiveUtterance]=[];var issues:[String]=[]
    var captured=0.0;var stage1=0;var stage2=0;var duringCapture=0;var stopped=false
    let began=Date(); var refiner:LivePreviewRefiner?;var evidence:URL?

    func record(_ kind:String,_ value:[String:Any]=[:]) { lock.lock();events.append(value.merging(["type":kind,"elapsed":Date().timeIntervalSince(began),"capturedSeconds":captured]){_,b in b});lock.unlock() }
    func event(_ event:LiveTranscriptEvent) {
        record("live",["event":event.type,"text":event.text,"start":event.start,"end":event.end])
        guard event.type=="commit",!event.text.isEmpty else { if event.type=="error" { issue(event.text) };return }
        lock.lock();stage1+=1
        let row=LiveUtterance(text:event.text,start:event.start,end:event.end);rows.append(row)
        if let first=pending.first,row.end-first.start>54 { _=refiner?.submit(rows:pending,sessionOffset:0);pending=[] }
        pending.append(row)
        if let first=pending.first,row.end-first.start>=30,let refiner {
            if refiner.submit(rows:pending,sessionOffset:0) != .retry { pending=[] }
        }
        lock.unlock()
    }
    func issue(_ message:String) {
        lock.lock();issues.append(message);let all=issues;lock.unlock()
        if let evidence {try? JSONEncoder().encode(all).write(to:evidence.appendingPathComponent("issues.json"),options:.atomic)}
        print("PIPELINE ISSUE:",message);record("issue",["message":message])
    }
    func update(_ value:ProgressiveSnapshot) {lock.lock();if !stopped {duringCapture+=1};lock.unlock();record("final",["completedFrames":value.completedFrames,"jobs":value.jobs,"text":value.text])}
    func refined(_ original:[LiveUtterance],_ refined:[TranscriptParagraph]) {
        lock.lock();if let replacement=LivePreviewRefiner.replacing(rows:rows,original:original,refined:refined,hotwords:[]) {rows=replacement;stage2+=1};lock.unlock()
        record("refined",["text":refined.map(\.text).joined()])
    }
}
@main struct ProgressiveRealPipelineSmoke {
    static func main() async throws {
        let args=CommandLine.arguments;let root=URL(fileURLWithPath:args[1]),original=URL(fileURLWithPath:args[2]),models=URL(fileURLWithPath:args[3]),engine=URL(fileURLWithPath:args[4])
        let language=args[5],rate=Double(args[6])!,target=Double(args[7])!,withLive=args.contains("--live")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let probe=ProgressiveProbe(),live=LiveTranscriptionSession()
        probe.evidence=root
        let resume=args.contains("--resume") || args.contains("--snapshot-only")
        let id=resume ? UUID(uuidString:original.deletingLastPathComponent().lastPathComponent)!:UUID()
        let capture=resume ? original.deletingLastPathComponent():root.appendingPathComponent("Capture/"+id.uuidString)
        try FileManager.default.createDirectory(at:capture,withIntermediateDirectories:true)
        let session=ProgressiveTranscriptionSession(model:models.appendingPathComponent("Qwen3ASR"),executable:engine.appendingPathComponent("qwen-asr"),language:language,hotwords:[],context:"",baseOffset:0,onUpdate:{probe.update($0)},onFailure:{probe.issue($0)})
        try session.bindCanonicalArchive(capture)
        if resume {
            let available=try CanonicalAudioReader(manifestURL:original).durationFrames
            let frames=target>0 ? Int64((target*16000).rounded()):available
            precondition(frames>0 && frames<=available)
            let final:ProgressiveSnapshot
            if args.contains("--snapshot-only") {final=session.currentSnapshot()!}
            else {final=try await session.finish(totalFrames:frames)}
            let paragraphs=try JSONSerialization.jsonObject(with:JSONEncoder().encode(final.paragraphs))
            let report:[String:Any]=["realInference":!args.contains("--snapshot-only") && !args.contains("--cached-only"),"resume":true,"text":final.text,"paragraphs":paragraphs,"coverageFrames":final.completedFrames,"durationSeconds":Double(frames)/16000,"issues":probe.issues,"events":probe.events,"batchCount":final.jobs,"seconds":Date().timeIntervalSince(probe.began)]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
            print("PASS: resumed saved capture without re-recording or losing acknowledged prefix");return
        }
        if withLive {
            let refiner=LivePreviewRefiner(model:models.appendingPathComponent("Qwen3ASR"),executable:engine.appendingPathComponent("qwen-asr"),language:language,hotwords:[],context:"",scratchRoot:root,onFailure:{probe.issue("stage2:"+$0)},onResult:{probe.refined($0,$1)})
            probe.refiner=refiner;live.onEvent={probe.event($0)}
            try live.start(model:models.appendingPathComponent("Paraformer"),executable:engine.appendingPathComponent("paraformer-live"),language:language)
        }
        let sink=MeetingAudioSink(directory:capture,started:1000,mode:.microphone,progressive:session,onAudio:{values in
            if withLive {probe.refiner?.append(values);live.append(values)}
        },canonicalRecordingID:id,onError:{probe.issue($0.localizedDescription)})
        let canonical=try CanonicalAudioInput.reader(for:original)
        let file=canonical == nil ? try AVAudioFile(forReading:original):nil
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        if let file { precondition(file.processingFormat.sampleRate==16000 && file.processingFormat.channelCount==1) }
        let sourceFrames=canonical?.durationFrames ?? file!.length
        let total=target>0 ? Int64((target*16000).rounded()):sourceFrames
        var frame:Int64=0
        let replayStart=Date()
        while frame<total {
            let position=frame%sourceFrames,n=Int(min(1600,total-frame,sourceFrames-position))
            let buffer:AVAudioPCMBuffer
            if let canonical {buffer=try canonical.read(startFrame:position,count:n)}
            else {buffer=AVAudioPCMBuffer(pcmFormat:file!.processingFormat,frameCapacity:AVAudioFrameCount(n))!;file!.framePosition=position;try file!.read(into:buffer,frameCount:AVAudioFrameCount(n))}
            precondition(buffer.frameLength==n)
            sink.appendMicrophone(buffer,at:1000+Double(frame)/16000)
            frame+=Int64(n);probe.lock.lock();probe.captured=Double(frame)/16000;probe.lock.unlock()
            // Pace the actual pipeline; do not accumulate the source in RAM.
            let delay=Double(frame)/16000/rate-Date().timeIntervalSince(replayStart)
            if delay>0 {try await Task.sleep(nanoseconds:UInt64(delay*1e9))}
        }
        let audio=try sink.finishCanonical(duration:Double(total)/16000)
        if withLive {await live.finish();probe.refiner?.cancel()}
        probe.lock.lock();probe.stopped=true;probe.lock.unlock();probe.record("stop")
        let before=session.currentSnapshot()!,final=try await session.finish(totalFrames:total)
        precondition(final.completedFrames==total && final.text==final.paragraphs.map{$0.separator+$0.text}.joined())
        let progressive=capture.deletingLastPathComponent().appendingPathComponent("Progressive/"+id.uuidString)
        let journal=try JSONSerialization.jsonObject(with:Data(contentsOf:progressive.appendingPathComponent("progress.json")))as! [String:Any]
        let jobs=journal["jobs"]as! [[String:Any]]
        precondition(jobs.first?["ownedStart"]as? Int==0 && jobs.last?["end"]as? Int==Int(total))
        for pair in zip(jobs,jobs.dropFirst()) {precondition(pair.0["end"]as! Int==pair.1["ownedStart"]as! Int)}
        var resultFiles:[URL:Data]=[:]
        for job in jobs {let f=progressive.appendingPathComponent((job["id"]as! String)+"-result.json");resultFiles[f]=try Data(contentsOf:f)}
        let restored=ProgressiveTranscriptionSession(model:models.appendingPathComponent("Qwen3ASR"),executable:engine.appendingPathComponent("qwen-asr"),language:language,hotwords:[],context:"",baseOffset:0,onUpdate:{_ in},onFailure:{probe.issue($0)})
        try restored.bindCanonicalArchive(capture)
        let again=try await restored.finish(totalFrames:total)
        precondition(again.text==final.text && again.paragraphs==final.paragraphs)
        for (file,data)in resultFiles {let reopened=try Data(contentsOf:file);precondition(reopened==data)}
        let reader=try CanonicalAudioReader(manifestURL:audio);precondition(reader.durationFrames==total)
        let paragraphs=try JSONSerialization.jsonObject(with:JSONEncoder().encode(final.paragraphs))
        probe.lock.lock();let report:[String:Any]=["realInference":true,"physicalCapture":false,"replaySpeed":rate,"language":language,"source":original.path,"durationSeconds":Double(total)/16000,"seconds":Date().timeIntervalSince(replayStart),"stage1Commits":probe.stage1,"stage2Applied":probe.stage2,"finalUpdatesDuringCapture":probe.duringCapture,"completedBeforeStop":Double(before.completedFrames)/16000,"batchCount":final.jobs,"coverageFrames":final.completedFrames,"text":final.text,"paragraphs":paragraphs,"issues":probe.issues,"events":probe.events,"checkpointReuse":true,"canonicalOriginal":audio.path];probe.lock.unlock()
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
        precondition(!final.text.isEmpty)
        if withLive { precondition(probe.stage1>0 && probe.stage2>0,"Both real-time captions and quick corrections must appear") }
        print("PASS: progressive real inference, contiguous canonical ownership, stage counts, stable saved result reuse")
    }
}
