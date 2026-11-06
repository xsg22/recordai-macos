import Foundation
import AVFoundation

@main struct LivePreviewLongUtteranceSmoke {
    struct Input: Decodable {
        struct Row: Decodable { let text:String; let start:Double; let end:Double }
        let path:String; let rows:[Row]; let hotwords:[String]?
    }
    final class Capture: @unchecked Sendable {
        let done=DispatchSemaphore(value:0)
        var originals:[LiveUtterance]=[];var result:[TranscriptParagraph]=[];var error:String?
    }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),worker=URL(fileURLWithPath:CommandLine.arguments[2])
        let real=CommandLine.arguments.count>4
        let model=real ? URL(fileURLWithPath:CommandLine.arguments[3]) : root.appendingPathComponent("unused-model")
        let rows:[LiveUtterance],samples:[Float]
        var words:[String]=[]
        if real {
            let input=try JSONDecoder().decode(Input.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[4])))
            rows=input.rows.map { LiveUtterance(text:$0.text,start:$0.start,end:$0.end) }
            words=input.hotwords ?? []
            let file=try AVAudioFile(forReading:URL(fileURLWithPath:input.path))
            precondition(file.processingFormat.sampleRate==16000 && file.processingFormat.channelCount==1)
            let pcm=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length))!
            try file.read(into:pcm);samples=Array(UnsafeBufferPointer(start:pcm.floatChannelData![0],count:Int(pcm.frameLength)))
        } else {
            rows=[LiveUtterance(text:"This is the first complete English sentence.",start:0,end:18),LiveUtterance(text:"This is the second complete English sentence.",start:18,end:38)]
            samples=[Float](repeating:0.04,count:38*16000)
            setenv("TALKTUCK_LIVE_TEST_TRACE",root.appendingPathComponent("transport.json").path,1)
        }
        defer { if !real {unsetenv("TALKTUCK_LIVE_TEST_TRACE")} }
        precondition(rows.count>=2 && rows.last!.end>30 && rows.last!.end<=54)
        precondition(rows.allSatisfy {$0.end-$0.start<=24})
        let suite="live-factory-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        defaults.set(root.appendingPathComponent("missing-old-cache").path,forKey:LiveRefinementCache.legacyPreferenceKey)
        let capture=Capture(),refiner=try LivePreviewRefiner.production(model:model,executable:worker,language:"en",hotwords:words,context:"",cacheBaseURL:root,migrationDefaults:defaults,onFailure:{capture.error=$0;capture.done.signal()}) { original,result in
            capture.originals=original;capture.result=result;capture.done.signal()
        }
        defer {refiner.cancel()}
        refiner.append(samples)
        guard case .queued = refiner.submit(rows:rows,sessionOffset:0) else {fatalError("Complete English batch beyond 30s rejected")}
        precondition(capture.done.wait(timeout:.now()+120) == .success,"No refinement callback")
        precondition(capture.error==nil && capture.originals==rows && !capture.result.isEmpty)
        precondition(defaults.object(forKey:LiveRefinementCache.legacyPreferenceKey)==nil)
        let duration=Double(samples.count)/16000
        precondition(capture.result.allSatisfy {($0.start ?? -1)>=0 && ($0.end ?? .infinity)<=duration+0.001})
        let mapped=LivePreviewRefiner.replacing(rows:rows,original:rows,refined:capture.result,hotwords:words)!
        precondition(mapped.first?.start==rows.first?.start && mapped.last?.end==rows.last?.end)
        if !real {
            let trace=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("transport.json"))) as! [[String:Any]]
            precondition(trace.count==1 && trace[0]["frames"] as? Int==38*16000,"Complete batch was hard-cut")
        }
        try JSONSerialization.data(withJSONObject:["realInference":real,"productionFactory":true,"legacyOverrideRemoved":true,"hotwordCount":words.count,"seconds":duration,"originalUtterances":rows.count,"originalsUnchanged":true,"text":capture.result.map(\.text).joined(separator:"\n")],options:.prettyPrinted).write(to:root.appendingPathComponent("result.json"))
        print("PASS: complete English utterances beyond 30s accepted, original IDs/times retained and full audio transported")
    }
}
