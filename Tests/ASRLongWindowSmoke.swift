import Foundation
import AVFoundation

@main struct ASRLongWindowSmoke {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),worker=URL(fileURLWithPath:CommandLine.arguments[2])
        let bin=root.appendingPathComponent("bin"),models=root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at:bin,withIntermediateDirectories:true)
        let executable=bin.appendingPathComponent("qwen-asr");try FileManager.default.copyItem(at:worker,to:executable)
        for name in ["Sortformer","QwenAligner"] {
            let dir=models.appendingPathComponent(name);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            try Data().write(to:dir.appendingPathComponent("model.safetensors"))
        }
        let audio=root.appendingPathComponent("speech.wav"),format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        do {
            let output=try AVAudioFile(forWriting:audio,settings:format.settings),buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!
            buffer.frameLength=16000;for i in 0..<16000 { buffer.floatChannelData![0][i]=Float(sin(Double(i)*0.05)*0.02) }
            for _ in 0..<130 { try output.write(from:buffer) }
        }
        let engine=TranscriptionEngine(temporaryRoot:root)
        for seconds in [45,60,120] {
            setenv("EXPECTED_WINDOW",String(seconds),1)
            let result=try engine.transcribe(audio:audio,model:models.appendingPathComponent("Qwen3ASR"),executable:executable,language:"zh",offlineWindows:true,windowSeconds:seconds,overlapSeconds:3)
            precondition(!result.text.isEmpty && result.paragraphs.first?.start==0 && result.paragraphs.last?.end==130)
            let rows=try engine.analyzeSpeakers(audio:audio,model:models.appendingPathComponent("Qwen3ASR"),executable:executable,transcript:result,language:"zh")
            precondition(rows.map { $0.separator+$0.text }.joined()==result.text)
            precondition(rows.first?.start==0 && rows.last?.end==130)
        }
        // Live uses complete, bounded utterances without another VAD pass.
        setenv("EXPECTED_WINDOW","8",1)
        let live=try engine.transcribe(audio:audio,model:models.appendingPathComponent("Qwen3ASR"),executable:executable,language:"zh",offlineWindows:true,windowSeconds:8,overlapSeconds:0)
        precondition(live.paragraphs.first?.start==0 && live.paragraphs.last?.end==130)
        print("PASS: 45/60/120 second windows, complete source coverage, long-window speaker alignment, text preservation and bounded live chunks")
    }
}
