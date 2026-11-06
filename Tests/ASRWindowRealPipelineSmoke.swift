import Foundation
import AVFoundation
import CryptoKit

@main struct ASRWindowRealPipelineSmoke {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),original=URL(fileURLWithPath:CommandLine.arguments[2])
        let model=URL(fileURLWithPath:CommandLine.arguments[3]),executable=URL(fileURLWithPath:CommandLine.arguments[4])
        let seconds=Int(CommandLine.arguments[5])!,language=CommandLine.arguments[6]
        let before=try digest(original)
        let canonical=CommandLine.arguments.contains("--canonical")
        let audio=canonical ? try makeCanonical(original,root:root) : original, started=Date()
        let engine=TranscriptionEngine(temporaryRoot:root,evidenceRoot:root)
        let wordsURL=ProcessInfo.processInfo.environment["TALKTUCK_TEST_HOTWORDS_JSON"].map { URL(fileURLWithPath:$0) }
        let hotwords=try wordsURL.map {try JSONDecoder().decode([String].self,from:Data(contentsOf:$0))} ?? []
        let output=try engine.transcribe(audio:audio,model:model,executable:executable,language:language,hotwords:hotwords,offlineWindows:true,windowSeconds:seconds)
        let recognitionSeconds=Date().timeIntervalSince(started)
        precondition(!output.text.isEmpty && output.paragraphs.contains { ($0.end ?? 0)-($0.start ?? 0)>30 })
        precondition(output.paragraphs.allSatisfy { ($0.end ?? 0)-($0.start ?? 0)<=300 })
        let aligned=try engine.analyzeSpeakers(audio:audio,model:model,executable:executable,transcript:output,language:language,hotwords:hotwords)
        precondition(aligned.map { $0.separator+$0.text }.joined()==output.text && !aligned.isEmpty)
        let duration:Double
        if let reader=try CanonicalAudioInput.reader(for:audio) {duration=Double(reader.durationFrames)/16000}
        else {duration=try AVAudioFile(forReading:audio).durationSecondsForWindowTest}
        precondition(aligned.allSatisfy {
            if $0.start == nil && $0.end == nil { return true }
            return ($0.start ?? -1)>=0 && ($0.end ?? .infinity)<=duration+0.1 && ($0.end ?? 0)>($0.start ?? 0)
        })
        for pair in zip(aligned,aligned.dropFirst()) { if let a=pair.0.start,let b=pair.1.start {precondition(b>=a-0.15,"Paragraph timing moved backwards across alignment partitions")} }
        let after=try digest(original);precondition(before.0==after.0 && before.1==after.1)
        let paragraphReport:[[String:Any]]=aligned.map { ["text":$0.text,"separator":$0.separator,"start":$0.start.map { $0 as Any } ?? NSNull(),"end":$0.end.map { $0 as Any } ?? NSNull(),"speakerIDs":$0.speakerIDs] }
        let report:[String:Any]=["realInference":true,"canonicalInput":(canonical || (try? CanonicalAudioInput.reader(for: audio)) != nil),"windowSeconds":seconds,"paragraphsBeforeAlignment":output.paragraphs.count,"paragraphsAfterAlignment":aligned.count,"textUnchangedByAlignment":true,"inputUnchanged":true,"durationSeconds":duration,"characters":output.text.count,"recognitionIncludingAlignmentGuideSeconds":recognitionSeconds,"wholePipelineSeconds":Date().timeIntervalSince(started),"text":output.text,"subtitlesBeforeAlignment":output.subtitles,"paragraphs":paragraphReport]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
        print("PASS: real long-window ASR + Sortformer + forced alignment, unchanged transcript and input audio")
    }
    private static func digest(_ url:URL) throws -> (String,Int) {
        let file=try FileHandle(forReadingFrom:url);defer {try? file.close()}
        var hash=SHA256(),bytes=0
        while let data=try file.read(upToCount:1024*1024),!data.isEmpty {hash.update(data:data);bytes+=data.count}
        return (hash.finalize().map {String(format:"%02x",$0)}.joined(),bytes)
    }
    private static func makeCanonical(_ audio:URL,root:URL) throws -> URL {
        let input=try AVAudioFile(forReading:audio),id=UUID(),directory=root.appendingPathComponent("canonical").appendingPathComponent(id.uuidString)
        let sealed=DispatchSemaphore(value:0)
        let writer=try MacSegmentedSourceWriter(directory:directory.appendingPathComponent("microphone"),recordingID:id,streamID:"microphone",startFrame:0,onSealed:{ _ in _ = sealed.signal() })
        let buffer=AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:8192)!
        var frames:Int64=0,nextSeal=10.0
        while input.framePosition<input.length {
            try input.read(into:buffer);precondition(buffer.frameLength>0)
            try writer.append(buffer,offset:Double(frames)/input.processingFormat.sampleRate);frames+=Int64(buffer.frameLength)
            while Double(frames)/input.processingFormat.sampleRate>=nextSeal {
                precondition(sealed.wait(timeout: .now()+30) == .success,"Synthetic fixture encoder did not seal its next segment")
                nextSeal+=10
            }
        }
        let track=try writer.finish()
        return try MacSegmentedManifest.finalize(recordingID:id,root:directory,trackManifests:[track])
    }
}
private extension AVAudioFile {
    var durationSecondsForWindowTest:Double { Double(length)/processingFormat.sampleRate }
}
