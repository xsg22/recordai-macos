import Foundation
import CryptoKit

/// Annotation and ownership are separate commits. A seam may need another
/// look while its immutable ASR, word alignment and voice state stay reusable.
enum ProgressiveAnalysisCache {
    struct Key: Codable, Equatable {
        var version=1
        var jobID:UUID
        var start:Int64
        var ownedStart:Int64
        var end:Int64
        var recognition:String
        var previousVoice:[String:String]
        var models:[String:String]
        var language:String
    }
    private struct Receipt:Codable { var key:Key;var files:[String:String] }
    static let names=["alignment.json","diarization.json","speaker.json","speaker.safetensors"]
    static func digest(_ url:URL) throws -> String {
        guard url.resolvingSymlinksInPath()==url else { throw BalancedAudioError.invalidManifest }
        return SHA256.hash(data:try Data(contentsOf:url,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined()
    }
    static func key(job:ProgressiveJob,root:URL,previous:ProgressiveJob?,model:URL,language:String) throws -> Key {
        var prior:[String:String]=[:],models:[String:String]=[:]
        if let previous { for ext in ["json","safetensors"] {
            prior[ext]=try digest(root.appendingPathComponent(previous.id.uuidString+"-speaker."+ext))
        } }
        for folder in [model,model.deletingLastPathComponent().appendingPathComponent("Sortformer"),model.deletingLastPathComponent().appendingPathComponent("QwenAligner")] {
            for name in ["model.safetensors","config.json"] {
                let url=folder.appendingPathComponent(name)
                if let v=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) {
                    models[url.path]="\(v.fileSize ?? 0):\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                }
            }
        }
        return Key(jobID:job.id,start:job.start,ownedStart:job.ownedStart,end:job.end,
                   recognition:try digest(root.appendingPathComponent(job.id.uuidString+"-asr.json")),previousVoice:prior,models:models,language:language)
    }
    static func directory(root:URL,job:ProgressiveJob)->URL { root.appendingPathComponent(job.id.uuidString+"-analysis") }
    static func valid(_ directory:URL,key:Key)->Bool {
        guard let data=try? Data(contentsOf:directory.appendingPathComponent("ready.json")),
              let receipt=try? JSONDecoder().decode(Receipt.self,from:data),receipt.key==key,
              Set(receipt.files.keys)==Set(names) else { return false }
        return names.allSatisfy { (try? digest(directory.appendingPathComponent($0)))==receipt.files[$0] }
    }
    static func save(from attempt:URL,to directory:URL,key:Key) throws {
        // Failed attempts are never deleted or replaced. The marker commits
        // only after all evidence is present, hashed and structurally checked.
        try validate(attempt,key:key)
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent("ready.json").path) {
            guard valid(directory,key:key) else { throw TranscriptionError.message("已有定稿候选检查点不一致，原音和候选已保留，未覆盖检查点。") }
            return
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var hashes:[String:String]=[:]
        for name in names {
            let source=attempt.appendingPathComponent(name),destination=directory.appendingPathComponent(name)
            try Data(contentsOf:source,options:.mappedIfSafe).write(to:destination,options:.atomic)
            hashes[name]=try digest(destination)
        }
        try BalancedAudioIO.save(Receipt(key:key,files:hashes),to:directory.appendingPathComponent("ready.json"))
    }
    static func validate(_ directory:URL,key:Key) throws {
        let state=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("speaker.json")))as? [String:Any]
        guard let seconds=state?["seconds"]as? Double,abs(seconds-Double(key.end)/16000)<0.001,
              FileManager.default.fileExists(atPath:directory.appendingPathComponent("speaker.safetensors").path),
              let alignment=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("alignment.json")))as? [String:Any],
              let words=alignment["alignedWords"]as? [[String:Any]],
              let voice=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("diarization.json")))as? [String:Any],voice["turns"] != nil,
              words.allSatisfy({ ($0["text"]as? String) != nil }) else { throw BalancedAudioError.invalidManifest }
    }
    static func matchesText(_ directory:URL,raw:TranscriptionOutput)->Bool {
        guard let data=try? Data(contentsOf:directory.appendingPathComponent("alignment.json")),
              let value=try? JSONSerialization.jsonObject(with:data)as? [String:Any],let words=value["alignedWords"]as? [[String:Any]] else { return false }
        return words.map{($0["separator"]as? String ?? "")+($0["text"]as? String ?? "")}.joined()==raw.text
    }
    static func importLegacy(root:URL,job:ProgressiveJob,key:Key,raw:TranscriptionOutput,priorText:String,to directory:URL) throws -> Bool {
        guard let data=try? Data(contentsOf:root.appendingPathComponent("last-failure.json")),
              let failure=try? JSONDecoder().decode([String:String].self,from:data),failure["jobId"]==job.id.uuidString else { return false }
        for attempt in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter({$0.lastPathComponent.hasPrefix("work-")}).sorted(by:{$0.path<$1.path}) {
            guard attempt.resolvingSymlinksInPath()==attempt,
                  let hints=try? Data(contentsOf:attempt.appendingPathComponent("prior.txt")),
                  let prior=try? JSONSerialization.jsonObject(with:hints)as? [String:Any],prior["context"]as? String==priorText,
                  matchesText(attempt,raw:raw),(try? validate(attempt,key:key)) != nil,
                  let written=try? attempt.appendingPathComponent("alignment.json").resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,
                  key.models.values.allSatisfy({(Double($0.split(separator:":").last ?? "") ?? .infinity)<=written.timeIntervalSince1970+0.01}) else { continue }
            try save(from:attempt,to:directory,key:key)
            try BalancedAudioIO.save(["source":attempt.lastPathComponent,"recognitionSHA256":key.recognition],to:directory.appendingPathComponent("legacy-import.json"))
            return true
        }
        return false
    }
    static func publishVoice(from directory:URL,root:URL,job:ProgressiveJob) throws {
        for ext in ["json","safetensors"] {
            try Data(contentsOf:directory.appendingPathComponent("speaker."+ext),options:.mappedIfSafe)
                .write(to:root.appendingPathComponent(job.id.uuidString+"-speaker."+ext),options:.atomic)
        }
    }
}
