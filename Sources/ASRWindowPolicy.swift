import Foundation

/// Local, bounded inference policy. Model capability is not a device memory or
/// latency guarantee. These preferences never affect stored original audio.
struct ASRWindowPolicy: Equatable, Sendable {
    static let maximumASRSeconds = 480
    static let maximumAlignmentSeconds = 300
    static let offlineChoices = [24,45,60,120,240,360,480]
    static let liveChoices = [6,8,12,16,24,30]
    let offlineSeconds: Int
    let liveTargetSeconds: Int
    let overlapSeconds = 3
    // One complete Paraformer utterance may last 24s. Retain that capability;
    // ordinary batches use the shorter target and never queue unbounded audio.
    var liveMaximumSeconds: Int { max(30, liveTargetSeconds + 24) }
    var liveAudioBufferSeconds: Int { liveMaximumSeconds > 30 ? 120 : 60 }

    init(offlineSeconds:Int = 24,liveTargetSeconds:Int = 8) {
        self.offlineSeconds = Self.offlineChoices.contains(offlineSeconds) ? offlineSeconds : 24
        self.liveTargetSeconds = Self.liveChoices.contains(liveTargetSeconds) ? liveTargetSeconds : 8
    }
    static func recommendedOfflineSeconds(language:String,memoryBytes:UInt64) -> Int {
        // Only the 16 GiB, 8-bit Mac path has been calibrated. Smaller machines
        // and languages without a reference corpus retain the previous bound.
        guard memoryBytes >= 16*1024*1024*1024 else { return 24 }
        switch language {
        case "zh": return 480
        case "en": return 360
        default: return 24
        }
    }
    static func recommendedLiveTargetSeconds(language:String,memoryBytes:UInt64) -> Int {
        guard memoryBytes >= 16*1024*1024*1024 else { return 8 }
        return ["zh", "en"].contains(language) ? 30 : 6
    }
    static func load(_ defaults:UserDefaults = .standard,language:String = "auto",memoryBytes:UInt64 = ProcessInfo.processInfo.physicalMemory) -> Self {
        let requested=defaults.object(forKey:"TalkTuck.asr.offlineWindowSeconds") as? Int
        let offline=requested.flatMap { offlineChoices.contains($0) ? $0 : nil } ?? recommendedOfflineSeconds(language:language,memoryBytes:memoryBytes)
        let requestedLive=defaults.object(forKey:"TalkTuck.asr.liveTargetSeconds") as? Int
        let live=requestedLive.flatMap { liveChoices.contains($0) ? $0 : nil } ?? recommendedLiveTargetSeconds(language:language,memoryBytes:memoryBytes)
        return Self(offlineSeconds:offline,
             liveTargetSeconds:live)
    }
}
