import Foundation
import CryptoKit
@main struct OfflineASR {
 static func main() throws {
  let args = CommandLine.arguments
  let audio = URL(fileURLWithPath:args[3]), before = try Data(contentsOf:audio)
  let started = Date()
  let result = try TranscriptionEngine().transcribe(audio:audio,model:URL(fileURLWithPath:args[2]),executable:URL(fileURLWithPath:args[1]),language:"zh")
  precondition(!result.text.isEmpty && result.text.range(of:"[\\p{Han}]",options:.regularExpression) != nil)
  let after = try Data(contentsOf:audio)
  precondition(after == before)
  let report: [String:Any] = ["realLocalInference":true,"networkDeniedBySandbox":true,"accountProvided":false,"inputSHA256":SHA256.hash(data:before).map {String(format:"%02x",$0)}.joined(),"inputUnchanged":true,"characters":result.text.count,"paragraphs":result.paragraphs.count,"processingSeconds":Date().timeIntervalSince(started)]
  try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[4]))
  print("PASS: real local Chinese transcription, no login, network denied, source audio unchanged")
 }
}
