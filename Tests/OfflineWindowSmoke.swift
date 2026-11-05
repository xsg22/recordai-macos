import Foundation
import AVFoundation
@main struct OfflineWindowSmoke {
 static func main() throws {
  precondition(TranscriptionEngine.removeExactOverlap("今天讨论产品的开发进度", "产品的开发进度接下来是测试") == "接下来是测试")
  precondition(TranscriptionEngine.removeExactOverlap("今天讨论产品的开发进度", "另外一个问题") == "另外一个问题")
  precondition(TranscriptionEngine.removeExactOverlap("好的", "好的，我们开始") == "好的，我们开始")
  let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory:true)
  let file = base.appendingPathComponent("silence.wav")
  let format = AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true)!
  let writer = try AVAudioFile(forWriting:file,settings:format.settings,commonFormat:.pcmFormatInt16,interleaved:true)
  let b = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!; b.frameLength=16000
  for i in 0..<16000 { b.int16ChannelData![0][i]=0 };try writer.write(from:b)
  let result = try TranscriptionEngine(temporaryRoot:base).transcribe(audio:file, model:base,executable:base.appendingPathComponent("should-not-run"),language:"zh",offlineWindows:true)
  precondition(result.text.isEmpty)
  print("PASS: overlap matching, short repeats preserved, silent window skipped")
 }
}
