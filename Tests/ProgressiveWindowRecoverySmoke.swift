import Foundation
import AVFoundation
@main struct ProgressiveWindowRecoverySmoke {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable=root.appendingPathComponent("qwen-asr"),calls=root.appendingPathComponent("calls.jsonl")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[2]),to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        setenv("TALKTUCK_RECOVERY_CALLS",calls.path,1);defer{unsetenv("TALKTUCK_RECOVERY_CALLS")}
        let audio=root.appendingPathComponent("fixture.wav"),format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        do {
            let file=try AVAudioFile(forWriting:audio,settings:format.settings),buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!
            buffer.frameLength=16000;buffer.floatChannelData![0].initialize(repeating:0.1,count:16000)
            for _ in 0..<400 {try file.write(from:buffer)}
        }
        var recovered:[Int]=[]
        let output=try TranscriptionEngine(temporaryRoot:root,evidenceRoot:root).transcribeBatch(audio:audio,model:root,executable:executable,language:"en",hotwords:[],context:"",windowSeconds:360,onRecovery:{recovered.append($0)})
        let attempts=try String(contentsOf:calls).split(separator:"\n").map{try JSONSerialization.jsonObject(with:Data($0.utf8))as! [String:Any]}
        precondition(recovered==[360] && attempts.count==5)
        precondition(output.paragraphs.count==4 && output.paragraphs.first?.start==0 && output.paragraphs.last?.end==400)
        precondition(attempts.dropFirst().allSatisfy{($0["end"]as! Double)-($0["start"]as! Double)<=120.001})
        precondition(!TranscriptionEngine.isRecoverableWindowFailure(CancellationError()))
        print("PASS: no truncated text published, finite failed-batch-only decoder recovery, 120s windows with 3s context cover all 400s")
    }
}
