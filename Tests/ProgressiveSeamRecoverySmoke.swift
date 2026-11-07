import Foundation
import AVFoundation

@main struct ProgressiveSeamRecoverySmoke {
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable=root.appendingPathComponent("qwen-asr"),calls=root.appendingPathComponent("calls.jsonl"),allow=root.appendingPathComponent("allow-seam")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[2]),to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        for folder in ["Sortformer","QwenAligner"] {let d=root.appendingPathComponent(folder);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);try Data().write(to:d.appendingPathComponent("model.safetensors"))}
        setenv("TALKTUCK_SEAM_CALLS",calls.path,1);setenv("TALKTUCK_SEAM_ALLOW",allow.path,1)
        defer {unsetenv("TALKTUCK_SEAM_CALLS");unsetenv("TALKTUCK_SEAM_ALLOW")}
        let capture=root.appendingPathComponent("Capture/"+UUID().uuidString),progress=capture.deletingLastPathComponent().appendingPathComponent("Progressive/"+capture.lastPathComponent)
        try FileManager.default.createDirectory(at:capture,withIntermediateDirectories:true)
        let sink=MeetingAudioSink(directory:capture,started:1000,canonicalRecordingID:UUID(uuidString:capture.lastPathComponent)!,onError:{_ in preconditionFailure("Fixture capture failed")})
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        for second in 0..<66 {
            let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!;buffer.frameLength=16000;buffer.floatChannelData![0].initialize(repeating:0.01,count:16000)
            sink.appendMicrophone(buffer,at:1000+Double(second));sink.setPaused(false,at:1001+Double(second))
        }
        let audio=try sink.finishCanonical(duration:66),original=try Data(contentsOf:audio)
        func session()->ProgressiveTranscriptionSession {ProgressiveTranscriptionSession(model:root.appendingPathComponent("Qwen3ASR"),executable:executable,language:"zh",hotwords:[],context:"",baseOffset:0,windowSeconds:24,onUpdate:{_ in},onFailure:{_ in})}
        let first=session();try first.bindCanonicalArchive(capture);first.observe(endFrame:66*16000,frameCount:66*16000,quiet:false)
        for _ in 0..<100 {if first.currentSnapshot()?.jobs==2 {break};try await Task.sleep(nanoseconds:100_000_000)}
        let partial=first.currentSnapshot()!
        precondition(partial.completedFrames==24*16000 && partial.jobs==2 && partial.pendingSeams==1,"Later jobs must proceed without falsely publishing across the seam")
        await first.cancelAndWait()
        let journal=try JSONSerialization.jsonObject(with:Data(contentsOf:progress.appendingPathComponent("progress.json")))as! [String:Any],jobs=journal["jobs"]as! [[String:Any]]
        precondition(jobs.count==3 && jobs[1]["status"]as? String=="seam-pending")
        var acknowledged:[URL:Data]=[:]
        for job in jobs where job["status"]as? String=="completed" {let f=progress.appendingPathComponent((job["id"]as! String)+"-result.json");acknowledged[f]=try Data(contentsOf:f)}
        let before=try String(contentsOf:calls).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8))as! [String:Any]}
        precondition(before.filter{$0["command"]as? String=="--transcribe-stream"}.count==3)
        precondition(before.filter{$0["command"]as? String=="--diarize-stream-checkpoint"}.count==3)
        let alignment=before.filter{$0["command"]as? String=="--align-stream"}
        precondition(alignment.count>3 && alignment.allSatisfy{($0["end"]as! Double)-($0["start"]as! Double)<=24})
        try Data().write(to:allow)
        let recovered=session();try recovered.bindCanonicalArchive(capture);let result=try await recovered.finish(totalFrames:66*16000)
        precondition(result.completedFrames==66*16000 && result.jobs==3 && result.pendingSeams==0)
        for (f,data)in acknowledged {let current=try Data(contentsOf:f);precondition(current==data)}
        let after=try String(contentsOf:calls).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8))as! [String:Any]}
        precondition(after.filter{$0["command"]as? String=="--transcribe-stream"}.count==3 && after.filter{$0["command"]as? String=="--diarize-stream-checkpoint"}.count==3,"Seam retry must reuse cached recognition and continuous voice state")
        let current=try Data(contentsOf:audio);precondition(current==original)
        let second=jobs[1],job=ProgressiveJob(id:UUID(uuidString:second["id"]as! String)!,start:Int64(second["start"]as! Int),ownedStart:Int64(second["ownedStart"]as! Int),end:Int64(second["end"]as! Int))
        let prior=jobs[0],previous=ProgressiveJob(id:UUID(uuidString:prior["id"]as! String)!,start:0,ownedStart:0,end:24*16000)
        let key=try ProgressiveAnalysisCache.key(job:job,root:progress,previous:previous,model:root.appendingPathComponent("Qwen3ASR"),language:"zh"),cache=ProgressiveAnalysisCache.directory(root:progress,job:job)
        precondition(ProgressiveAnalysisCache.valid(cache,key:key))
        try Data("tampered".utf8).write(to:cache.appendingPathComponent("alignment.json"))
        precondition(!ProgressiveAnalysisCache.valid(cache,key:key),"Unbound or corrupted candidate evidence must never be reused")
        print("PASS: persistent seam failure, later jobs continue, prefix publication waits, bounded local alignment, restart retries only seam, acknowledged results/original unchanged, cache tamper rejected")
    }
}
