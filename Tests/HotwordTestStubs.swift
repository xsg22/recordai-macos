import Foundation
actor GemmaRuntime {
    static let shared = GemmaRuntime()
    nonisolated static func configurationAvailable() -> Bool { false }
    func generate(system: String, prompt: String, onToken: @escaping @Sendable (String) -> Void) async throws -> String { "[]" }
}
actor HotwordLocalRuntime {
    static let shared = HotwordLocalRuntime()
    nonisolated static func configurationAvailable() -> Bool { false }
    func generate(system: String, prompt: String) async throws -> String { "[]" }
}
enum TranscriptionError: LocalizedError { case message(String) }
struct LibrarySyncAccess { var server: URL; var token: String; var userId: UUID }
