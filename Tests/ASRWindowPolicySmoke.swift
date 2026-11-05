import Foundation
@main struct ASRWindowPolicySmoke {
    static func main() {
        for value in ASRWindowPolicy.offlineChoices { precondition(ASRWindowPolicy(offlineSeconds:value).offlineSeconds == value) }
        for value in ASRWindowPolicy.liveChoices { precondition(ASRWindowPolicy(liveTargetSeconds:value).liveTargetSeconds == value) }
        precondition(ASRWindowPolicy(offlineSeconds:1200).offlineSeconds == ASRWindowPolicy().offlineSeconds)
        precondition(ASRWindowPolicy(liveTargetSeconds:0).liveTargetSeconds == ASRWindowPolicy().liveTargetSeconds)
        precondition(ASRWindowPolicy.maximumASRSeconds < 1200 && ASRWindowPolicy.maximumAlignmentSeconds == 300)
        let memory:UInt64=16*1024*1024*1024
        precondition(ASRWindowPolicy.recommendedOfflineSeconds(language:"zh",memoryBytes:memory)==240)
        precondition(ASRWindowPolicy.recommendedOfflineSeconds(language:"en",memoryBytes:memory)==45)
        precondition(ASRWindowPolicy.recommendedOfflineSeconds(language:"yue",memoryBytes:memory)==24)
        precondition(ASRWindowPolicy.recommendedOfflineSeconds(language:"auto",memoryBytes:memory)==24)
        precondition(ASRWindowPolicy.recommendedOfflineSeconds(language:"zh",memoryBytes:8*1024*1024*1024)==24)
        print("PASS: independent live/offline choices, bounded fallbacks and separate aligner limit")
    }
}
