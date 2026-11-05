import Foundation

// Canonical recording semantics. Mac vendors this file verbatim; disk archives and network DTOs use adapters.
enum RecordingOrigin: String, Codable, CaseIterable {
    case watch, iphone, macos, imported, unknown
    var symbol: String {
        switch self { case .watch: return "applewatch"; case .iphone: return "iphone"; case .macos: return "desktopcomputer"; case .imported: return "square.and.arrow.down"; case .unknown: return "questionmark.circle" }
    }
    var title: String {
        switch self { case .watch: return "Apple Watch"; case .iphone: return "iPhone"; case .macos: return "Mac"; case .imported: return "文件导入"; case .unknown: return "未知来源" }
    }
}
enum TranscriptionOrigin: String, Codable { case local, remote, notGenerated }
enum RecordingCapturePhase: String, Codable { case unknown, recording, paused, sealing, finished, interrupted, failed }
enum RecordingProcessingPhase: String, Codable { case notRequested, needsModel, queued, processing, ready, noSpeech, failed }
enum RecordingTransferPhase: String, Codable { case localOnly, queued, sending, received, verified, failed
    var isPending: Bool { self == .queued || self == .sending }
}
enum RecordingAudioAvailability: String, Codable { case local, remoteOnly, missing, unverified }
enum RecordingPresentationPhase: String, Codable { case recording, paused, saving, syncing, processing, ready, saved, interrupted, failed }

struct RecordingStateModel: Codable, Equatable {
    var origin: RecordingOrigin
    var capture: RecordingCapturePhase
    var localTranscription: RecordingProcessingPhase
    var remoteTranscription: RecordingProcessingPhase
    var transfer: RecordingTransferPhase
    var audio: RecordingAudioAvailability
    var presentation: RecordingPresentationPhase {
        if capture == .recording { return .recording }
        if capture == .paused { return .paused }
        if capture == .sealing { return .saving }
        if capture == .interrupted { return .interrupted }
        if capture == .failed || transfer == .failed { return .failed }
        if transfer.isPending { return .syncing }
        if [localTranscription,remoteTranscription].contains(where: { $0 == .queued || $0 == .processing }) { return .processing }
        if localTranscription == .ready || remoteTranscription == .ready { return .ready }
        if localTranscription == .failed || remoteTranscription == .failed { return .failed }
        return .saved
    }
    static func processing(_ state: String?) -> RecordingProcessingPhase {
        switch state {
        case "queued": return .queued
        case "recognizing", "transcribing": return .processing
        case "ready": return .ready
        case "no_speech": return .noSpeech
        case "unavailable": return .needsModel
        case "failed": return .failed
        default: return .notRequested
        }
    }
    // Remote inference/title generation and user-selected final-text sync are separate permissions.
    static func allowsRemoteTranscript(_ origin: TranscriptionOrigin) -> Bool { origin == .remote }
    static func allowsFinalTranscriptSync(_ origin: TranscriptionOrigin, isFinal: Bool) -> Bool { isFinal && origin != .notGenerated }
}
