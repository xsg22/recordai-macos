import Foundation
import AVFoundation

@main struct ASRWindowRealPipelineSmoke {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),audio=URL(fileURLWithPath:CommandLine.arguments[2])
        let model=URL(fileURLWithPath:CommandLine.arguments[3]),executable=URL(fileURLWithPath:CommandLine.arguments[4])
        let seconds=Int(CommandLine.arguments[5])!,language=CommandLine.arguments[6]
        let before=try LibraryAudioFiles.digest(audio)
        let engine=TranscriptionEngine(temporaryRoot:root)
        let output=try engine.transcribe(audio:audio,model:model,executable:executable,language:language,offlineWindows:true,windowSeconds:seconds)
        precondition(!output.text.isEmpty && output.paragraphs.contains { ($0.end ?? 0)-($0.start ?? 0)>30 })
        let aligned=try engine.analyzeSpeakers(audio:audio,model:model,executable:executable,transcript:output,language:language)
        precondition(aligned.map { $0.separator+$0.text }.joined()==output.text && !aligned.isEmpty)
        let duration=try AVAudioFile(forReading:audio).durationSecondsForWindowTest
        precondition(aligned.allSatisfy { ($0.start ?? -1)>=0 && ($0.end ?? .infinity)<=duration+0.1 })
        let after=try LibraryAudioFiles.digest(audio);precondition(before.0==after.0 && before.1==after.1)
        let report:[String:Any]=["realInference":true,"windowSeconds":seconds,"paragraphsBeforeAlignment":output.paragraphs.count,"paragraphsAfterAlignment":aligned.count,"textUnchangedByAlignment":true,"inputUnchanged":true,"durationSeconds":duration,"characters":output.text.count]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
        print("PASS: real long-window ASR + Sortformer + forced alignment, unchanged transcript and input audio")
    }
}
private extension AVAudioFile {
    var durationSecondsForWindowTest:Double { Double(length)/processingFormat.sampleRate }
}
