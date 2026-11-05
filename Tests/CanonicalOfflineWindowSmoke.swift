import Foundation
@main struct CanonicalWindow {
 static func main() throws {
  let base=URL(fileURLWithPath: CommandLine.arguments[1],isDirectory:true), bin=base.appendingPathComponent("bin"), root=base.appendingPathComponent("capture"), id=UUID()
  try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
  let worker=bin.appendingPathComponent("qwen-asr")
  try FileManager.default.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[2]),to:worker)
  let mic=try MacSegmentedTrackWriter(directory:root.appendingPathComponent("microphone"),recordingID:id,streamID:"microphone",startFrame:0)
  try mic.append([Float](repeating:0.05,count:768000),startFrame:0)
  let manifest=try MacSegmentedManifest.finalize(recordingID:id,root:root,trackManifests:[try mic.finish()])
  setenv("WINDOW_TEST","1",1)
  let result=try TranscriptionEngine(temporaryRoot:base).transcribe(audio:manifest,model:base,executable:worker,language:"zh",offlineWindows:true)
  precondition(result.paragraphs.count == 3 && result.paragraphs.map(\.start) == [0, 21, 42])
  print("PASS: offline windows process canonical recording with relative timestamps")
 }
}
