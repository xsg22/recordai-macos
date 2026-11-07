import Foundation

/// One optional heavy worker at a time, independent of window visibility.
/// The audio callback never waits here. Processes exit between jobs, releasing
/// model allocations rather than retaining a second resident finalizer.
enum InferenceGate {
    private static let lock = NSRecursiveLock()
    static func enter() { lock.lock() }
    static func leave() { lock.unlock() }
    static var coordinationPath: String { FileManager.default.temporaryDirectory.appendingPathComponent("talktuck-inference.lock").path }
}
