import Foundation
@main struct MultilingualSentenceSmoke {
    static func main() throws {
        let cases: [(String,[String])] = [
            ("你好。再见！",["你好。","再见！"]),
            ("Dr. Smith paid 3.14 at example.com. Then he left!",["Dr. Smith paid 3.14 at example.com. ","Then he left!"]),
            ("Use v0.17.3, e.g. this build. Done?",["Use v0.17.3, e.g. this build. ","Done?"]),
            ("「こんにちは。」次です！",["「こんにちは。」","次です！"]),
            ("أهلاً؟ نعم!",["أهلاً؟ ","نعم!"]),
            ("पहला वाक्य। दूसरा वाक्य॥",["पहला वाक्य। ","दूसरा वाक्य॥"]),
            ("«Très bien !» Ensuite.",["«Très bien !» ","Ensuite."])]
        for (text,expected) in cases {
            let chars=Array(text);let edges=[0]+SentencePolicy.boundaries(chars).union([chars.count]).sorted()
            let actual=zip(edges,edges.dropFirst()).filter{$0<$1}.map{String(chars[$0..<$1])}
            precondition(actual==expected,"\(text): \(actual)")
            precondition(actual.joined()==text)
            let rows=TranscriptReadability.fallback(text)
            precondition(rows.map(\.text).joined()==text)
        }
        let english=String(repeating:"A useful sentence with enough words to preserve whole tokens. ",count:20)
        let rows=TranscriptReadability.fallback(english)
        precondition(rows.count>1 && rows.map(\.text).joined()==english)
        let left=TranscriptParagraph(text:"जी।",start:0,end:0.3,audioFile:"a",speakerIDs:["0"])
        let right=TranscriptParagraph(text:"हाँ।",start:0.4,end:0.7,audioFile:"a",speakerIDs:["0"])
        precondition(TranscriptReadability.groups([left,right]).count==2,"Reading UI must respect non-Latin sentence terminals")
        print("PASS: shared Unicode terminals, closing quotes, abbreviations, decimals, domains, versions and whole-word reading groups")
    }
}
