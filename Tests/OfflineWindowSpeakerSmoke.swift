import Foundation
import AVFoundation
@main struct AlignmentSmoke {
 static func main() throws {
  let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true), models=base.appendingPathComponent("models"), bin=base.appendingPathComponent("bin"), audio=base.appendingPathComponent("audio.wav")
  try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
  for name in ["Sortformer","QwenAligner"] { let p=models.appendingPathComponent(name); try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true);try Data().write(to:p.appendingPathComponent("model.safetensors")) }
  let executable=bin.appendingPathComponent("qwen-asr");try FileManager.default.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[2]),to:executable)
  let f=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true)!
  do { let w=try AVAudioFile(forWriting:audio,settings:f.settings,commonFormat:.pcmFormatInt16,interleaved:true);let b=AVAudioPCMBuffer(pcmFormat:f,frameCapacity:16000)!; b.frameLength=16000;for i in 0..<16000 { b.int16ChannelData![0][i]=1000 };try w.write(from:b) }
  let text="测试语音", transcript=TranscriptionOutput(text:text,subtitles:"",paragraphs:[TranscriptParagraph(text:text,separator:"",start:0,end:1)])
  let result=try TranscriptionEngine(temporaryRoot:base).analyzeSpeakers(audio:audio,model:models.appendingPathComponent("Qwen3ASR"),executable:executable,transcript:transcript)
  precondition(result.count==1 && result[0].text==text && result[0].speakerIDs==["0"])
  print("PASS: standard audio speaker attribution uses transcript windows")
 }
}
