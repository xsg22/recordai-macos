import Foundation
@main struct TranscriptParagraphPolicySmoke {
    static func main() throws {
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
        print("PASS: 50-character fallback, immutable text, pending timing, protected words, hard speaker/gap boundaries, aligned save/SRT/playback")
    }
}
