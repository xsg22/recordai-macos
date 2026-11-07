import Foundation
@main struct TranscriptParagraphPolicySmoke {
    @MainActor static func main() throws {
        let text = String(repeating: String(repeating: "字", count: 30) + "。", count: 4)
        let rows = TranscriptReadability.fallback(text)
        precondition(rows.count == 2 && rows.map(\.text).joined() == text)
        precondition(rows.allSatisfy { $0.start == nil && $0.end == nil })
        let protected = String(repeating: "字", count: 49) + "TalkTuck" + String(repeating: "文", count: 60)
        let named = TranscriptReadability.fallback(protected, hotwords: ["TalkTuck"])
        precondition(named.map(\.text).joined() == protected && named.contains { $0.text.contains("TalkTuck") })
        let a = TranscriptParagraph(text: "页", start: 0, end: 0.2, audioFile: "a", speakerIDs: ["0"])
        let b = TranscriptParagraph(text: "面", start: 0.2, end: 0.4, audioFile: "a", speakerIDs: ["1"])
        precondition(TranscriptReadability.groups([a,b]).count == 2)
        var same = b; same.speakerIDs = ["0"]
        precondition(TranscriptReadability.groups([a,same]).count == 1)
        var paused = same; paused.start = 5.201; paused.end = 5.4
        precondition(TranscriptReadability.groups([a,paused]).count == 2)
        var record = MeetingRecord(title: "policy", text: "", status: .recorded)
        record.audioFiles = ["a"]; record.audioDurations = ["a": 20]
        let base = TranscriptionOutput(text: "第一句。第二句。", subtitles: "", paragraphs: [TranscriptParagraph(text: "第一句。第二句。",start:0,end:20)])
        try MeetingRecordingAppend.apply(outputs:[base.readingFallback()],files:["a"],durations:[20],appending:false,to:&record)
        precondition(record.hasCurrentParagraphs && record.transcriptParagraphs.allSatisfy { $0.start == nil })
        let aligned = [TranscriptParagraph(text:"第一句。",start:1,end:2,speakerIDs:["0"]),TranscriptParagraph(text:"第二句。",start:8,end:9,speakerIDs:["0"])]
        try MeetingRecordingAppend.applySpeakerParagraphs(aligned,base:base,file:"a",to:&record)
        precondition(record.hasCurrentParagraphs && record.transcriptParagraphs.count == 2 && record.subtitles.contains("00:00:08,000"))
        precondition(TranscriptPlaybackRange(paragraph:record.transcriptParagraphs[1],record:record)?.start == 8)
        // A missing prefix time never creates a separate display/storage row.
        let full = "我说完。"
        var partial = record; partial.text = full; partial.status = .completed
        partial.transcriptParagraphs = [TranscriptParagraph(text:full,start:0,end:20,audioFile:"a")]
        let beforeSRT = partial.subtitles
        let uncertain = TranscriptParagraph(text:full,speakerIDs:["0"],alignedStart:1,alignedEnd:2)
        try MeetingRecordingAppend.applySpeakerParagraphs([uncertain],base:TranscriptionOutput(text:full,subtitles:"",paragraphs:[]),file:"a",to:&partial)
        precondition(partial.transcriptParagraphs.count == 1 && partial.paragraphText == full && partial.subtitles == beforeSRT)
        let p = partial.transcriptParagraphs[0]
        precondition(p.start == nil && p.end == nil && p.localStart == 1 && TranscriptPlaybackRange(paragraph:p,record:partial)?.end == 2)
        var shifted = uncertain; shifted.audioFile = "b"; shifted.applyAudioOffset(10)
        var continued = partial; continued.audioFiles = ["a","b"]; continued.audioDurations = ["a":10,"b":20]
        precondition(shifted.start == nil && shifted.alignedStart == 11 && shifted.localStart == 1 && TranscriptPlaybackRange(paragraph:shifted,record:continued)?.start == 1)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("sentence-time-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library=try MeetingLibrary(root:root), user=UUID()
        let adapter=MacLibrarySyncAdapter(library:library);try adapter.activate(userId:user)
        partial.userId=user;_ = try library.save(partial)
        let value=try adapter.values(userId:user).first { $0.recording?.id==partial.id }!
        precondition(value.recording!.paragraphs[0].startMs==nil && value.recording!.paragraphs[0].endMs==nil,"Local partial bounds must not become exact cloud timestamps")
        try adapter.apply(LibrarySyncEntity(kind:.recording,id:partial.id,version:1,value:value),userId:user)
        let saved=try library.load(partial.id)
        precondition(saved.transcriptParagraphs.count==1 && saved.transcriptParagraphs[0].alignedStart==1 && saved.transcriptParagraphs[0].alignedEnd==2)
        let published=try AgentDataPublisher.snapshot(saved,libraryRoot:root)
        precondition(published.paragraphs[0].start==nil && published.paragraphs[0].alignedStart==1 && published.paragraphs[0].text==full)
        var changed=value; changed.recording!.paragraphs[0].text="人工改写。"
        try adapter.apply(LibrarySyncEntity(kind:.recording,id:partial.id,version:2,value:changed),userId:user)
        let changedRecord=try library.load(partial.id)
        precondition(changedRecord.transcriptParagraphs[0].alignedStart==nil,"Remote text edits invalidate the old partial alignment")
        print("PASS: 50-character fallback, immutable text, pending timing, protected words, hard speaker/gap boundaries, aligned save/SRT/playback")
    }
}
