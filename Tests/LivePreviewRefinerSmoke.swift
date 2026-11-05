import Foundation

@main struct LivePreviewRefinerSmoke {
 static func main() {
  let before=LiveUtterance(text:"before",start:0,end:2), first=LiveUtterance(text:"薛胜国",start:2.1,end:4), second=LiveUtterance(text:"talk talk",start:4.2,end:7), after=LiveUtterance(text:"after",start:7.2,end:9)
  let rows=[before,first,second,after], words=["TalkTuck","薛圣国","codex","张三","李四","王五","小猫钓鱼"]
  let name=TranscriptParagraph(text:"薛圣国", start:0.1,end:1.8), project=TranscriptParagraph(text:"TalkTuck",start:2.2,end:4.8)
  guard let result=LivePreviewRefiner.replacing(rows:rows,original:[first,second],refined:[name,project],hotwords:words) else { fatalError("missing replacement") }
  precondition(result.count==4 && result[0]==before && result[3]==after)
  precondition(result[1].text=="薛圣国" && result[1].start==2.1 && result[1].end==4)
  precondition(result[2].text=="TalkTuck" && result[2].start==4.2 && result[2].end==7)
  let merged=TranscriptParagraph(text:"薛圣国 TalkTuck",start:0.1,end:4.8)
  let grouped=LivePreviewRefiner.replacing(rows:rows,original:[first,second],refined:[merged],hotwords:words)!
  precondition(grouped.count==3 && grouped[1].start==2.1 && grouped[1].end==7)
  precondition(LivePreviewRefiner.replacing(rows:rows,original:[second,first],refined:[name],hotwords:words)==nil)
  precondition(LivePreviewRefiner.replacing(rows:rows,original:[first,after],refined:[name],hotwords:words)==nil)
  precondition(LivePreviewRefiner.replacing(rows:result,original:[first],refined:[name],hotwords:words)==nil)
  var changed=first; changed.text="用户修改"
  precondition(LivePreviewRefiner.replacing(rows:[before,changed,second,after],original:[first],refined:[name],hotwords:words)==nil)
  let natural=LiveUtterance(text:"我叫薛胜国我现在在开发一款叫 talk tap 的 app 它包含利用 code x 开发",start:0,end:11)
  let corrected=TranscriptParagraph(text:"我叫薛圣国，我现在在开发一款叫做 TalkTuck 的 APP，它包含利用 Codex 开发。",start:0.1,end:10.5)
  let normal=LivePreviewRefiner.replacing(rows:[natural],original:[natural],refined:[corrected],hotwords:words)
  precondition(normal?.first?.text == corrected.text && normal?.first?.start == 0 && normal?.first?.end == 11, "natural speech mentioning three hotwords must not be rejected")
  let fabricated=TranscriptParagraph(text:"TalkTuck，薛圣国，codex，张三。",start:0.1,end:1.8)
  let safe=LivePreviewRefiner.replacing(rows:rows,original:[first,second],refined:[fabricated,project],hotwords:words)!
  precondition(safe[1]==first && safe[2].text=="TalkTuck")
  precondition(LivePreviewRefiner.replacing(rows:rows,original:[first],refined:[fabricated],hotwords:words)==nil)
  print("PASS: time-based mapping preserves individual bounds, rejects stale results and filters hotword-list hallucination")
 }
}
