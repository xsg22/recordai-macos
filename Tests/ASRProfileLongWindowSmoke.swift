import Foundation
import AVFoundation
@main struct ASRProfileLongWindowSmoke {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),worker=URL(fileURLWithPath:CommandLine.arguments[2])
  let bin=root.appendingPathComponent("bin"),models=root.appendingPathComponent("models")
  try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
  for name in ["Sortformer","QwenAligner"] {let p=models.appendingPathComponent(name);try FileManager.default.createDirectory(at:p,withIntermediateDirectories:true);try Data().write(to:p.appendingPathComponent("model.safetensors"))}
  let executable=bin.appendingPathComponent("qwen-asr");try FileManager.default.copyItem(at:worker,to:executable)
  let audio=root.appendingPathComponent("speech.wav"),format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true)!
  do { let out=try AVAudioFile(forWriting:audio,settings:format.settings,commonFormat:.pcmFormatInt16,interleaved:true),b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!;b.frameLength=16000;for i in 0..<16000 {b.int16ChannelData![0][i]=1000};for _ in 0..<950 {try out.write(from:b)} }
  let engine=TranscriptionEngine(temporaryRoot:root),model=models.appendingPathComponent("Qwen3ASR")
  let result=try engine.transcribe(audio:audio,model:model,executable:executable,language:"en",offlineWindows:true,windowSeconds:480)
  precondition(result.text=="Alice reviewed the design. Bob will implement it, tomorrow.\nCarol will verify it.")
  precondition(result.paragraphs.allSatisfy { ($0.end ?? 0)-($0.start ?? 0)<=300 })
  let aligned=try engine.analyzeSpeakers(audio:audio,model:model,executable:executable,transcript:result,language:"en")
  precondition(aligned.map { $0.separator+$0.text }.joined()==result.text)
  setenv("BAD_ALIGNMENT_ORDER","1",1)
  do {_=try engine.analyzeSpeakers(audio:audio,model:model,executable:executable,transcript:result,language:"en");preconditionFailure("Backwards alignment accepted")} catch {}
  unsetenv("BAD_ALIGNMENT_ORDER")
  setenv("BAD_ALIGNMENT_PARTS","1",1);defer {unsetenv("BAD_ALIGNMENT_PARTS");unsetenv("NO_ALIGNMENT_PARTS")}
  do { _=try engine.transcribe(audio:audio,model:model,executable:executable,language:"en",offlineWindows:true,windowSeconds:480);preconditionFailure("Corrupt alignment metadata accepted") } catch { }
  unsetenv("BAD_ALIGNMENT_PARTS");setenv("NO_ALIGNMENT_PARTS","1",1)
  let retained=try engine.transcribe(audio:audio,model:model,executable:executable,language:"en",offlineWindows:true,windowSeconds:480)
  precondition(retained.text==result.text)
  do {_=try engine.analyzeSpeakers(audio:audio,model:model,executable:executable,transcript:retained,language:"en");preconditionFailure("Unbounded timestamp analysis accepted")} catch {}
  print("PASS:480s transport, <=300s alignment clips, overlap trim, exact text/separators, corrupted metadata rejection and completed-text retention")
 }
}
