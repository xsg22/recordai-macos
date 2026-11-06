import Foundation

@main struct LiveRefinementCacheSmoke {
    final class Capture: @unchecked Sendable {
        let done=DispatchSemaphore(value:0)
        var error:String?;var result:[TranscriptParagraph]=[]
    }
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),worker=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="cache-migration-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let legacy=root.appendingPathComponent("missing-old-mount/Models")
        defaults.set(legacy.path,forKey:LiveRefinementCache.legacyPreferenceKey)
        defaults.set(legacy.path,forKey:"LiveHotwordModelDirectory")
        let base=root.appendingPathComponent("cache");try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let trace=root.appendingPathComponent("transport.json");setenv("TALKTUCK_CACHE_TEST_TRACE",trace.path,1);defer {unsetenv("TALKTUCK_CACHE_TEST_TRACE")}
        let captured=Capture(),unused=root.appendingPathComponent("unused-model")
        let refiner=try LivePreviewRefiner.production(model:unused,executable:worker,language:"en",hotwords:["Codex","TalkTuck","TestName"],context:"",cacheBaseURL:base,migrationDefaults:defaults,onFailure:{captured.error=$0;captured.done.signal()}) { _,result in captured.result=result;captured.done.signal() }
        defer {refiner.cancel()}
        precondition(defaults.object(forKey:LiveRefinementCache.legacyPreferenceKey)==nil)
        precondition(defaults.object(forKey:"LiveHotwordModelDirectory")==nil)
        precondition(!FileManager.default.fileExists(atPath:legacy.path))
        let managed=try LiveRefinementCache.prepare(baseURL:base)
        // macOS is allowed to purge caches. The production factory must recover
        // its own empty cache directory, without reviving a legacy mount path.
        try FileManager.default.removeItem(at:managed)
        let rows=[LiveUtterance(text:"Test name uses code x.",start:0,end:18),LiveUtterance(text:"It builds talk tuck.",start:18,end:38)]
        refiner.append([Float](repeating:0.03,count:38*16000))
        guard case .queued = refiner.submit(rows:rows,sessionOffset:0)else {fatalError("Batch rejected")}
        precondition(captured.done.wait(timeout:.now()+15) == .success)
        precondition(captured.error==nil && captured.result.first?.text.contains("Codex")==true)
        let output=try JSONSerialization.jsonObject(with:Data(contentsOf:trace))as! [String:Any]
        precondition((output["output"]as! String).hasPrefix(managed.path+"/"))
        precondition(output["hotwords"]as! [String]==["Codex","TalkTuck","TestName"])
        let failure=Capture(),base2=root.appendingPathComponent("blocked");try FileManager.default.createDirectory(at:base2,withIntermediateDirectories:true)
        let blocked=try LiveRefinementCache.prepare(baseURL:base2)
        let bad=try LivePreviewRefiner.production(model:unused,executable:worker,language:"en",hotwords:[],context:"",cacheBaseURL:base2,onFailure:{failure.error=$0;failure.done.signal()}) { _,_ in fatalError("Unavailable cache must not invoke worker") }
        defer {bad.cancel()}
        try FileManager.default.removeItem(at:blocked);try Data("blocked".utf8).write(to:blocked)
        bad.append([Float](repeating:0.03,count:38*16000));guard case .queued = bad.submit(rows:rows,sessionOffset:0)else {fatalError("Batch rejected")}
        precondition(failure.done.wait(timeout:.now()+5) == .success && failure.error=="cacheUnavailable")
        precondition(rows[0].text=="Test name uses code x.")
        print("PASS: production factory ignores/migrates stale override, recreates purged cache, passes confirmed vocabulary and reports unavailable cache without changing original captions")
    }
}
