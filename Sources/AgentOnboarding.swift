import Foundation

/// Persists presentation, rather than transcript arrival; keeps the visible banner until dismissed.
final class AgentOnboarding {
    private let marker: URL
    private(set) var seen: Bool
    init(storage: URL) {
        marker = storage.appendingPathComponent("agent-onboarding-v1.json")
        seen = (try? Data(contentsOf: marker)).flatMap { try? JSONDecoder().decode(Bool.self, from: $0) } ?? false
    }
    func eligible(_ record: MeetingRecord) -> Bool {
        !seen && record.status == .completed && !record.audioFiles.isEmpty && record.pendingAudioFiles.isEmpty && !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func markSeen() throws {
        guard !seen else { return }
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(true).write(to: marker, options: .atomic)
        seen = true
    }
}
