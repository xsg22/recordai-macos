import Foundation

/// App-owned operational events only. Never pass transcript, audio, credentials or request bodies.
final class FeedbackDiagnostics: @unchecked Sendable {
    static let shared = FeedbackDiagnostics()
    private let queue = DispatchQueue(label: "com.xsg.talktuck.feedback-diagnostics", qos: .utility)
    private let root: URL
    private let maximumBytes: UInt64
    private let archiveCount: Int
    private var lastWriteError: Error?

    init(root: URL? = nil, maximumBytes: UInt64 = 5_000_000, archiveCount: Int = 4) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CoHearTranscribe", isDirectory: true).appendingPathComponent("FeedbackDiagnostics", isDirectory: true)
        self.maximumBytes = maximumBytes; self.archiveCount = max(1, archiveCount)
    }

    func record(_ component: String, _ event: String, fields: [String: Any] = [:], at date: Date = Date()) {
        let timestamp = ISO8601DateFormatter().string(from: date)
        queue.async {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let current = self.root.appendingPathComponent("events.jsonl")
                let value: [String: Any] = ["time": timestamp, "timestamp": date.timeIntervalSince1970, "component": component, "event": event, "fields": fields]
                var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
                let size = ((try? fm.attributesOfItem(atPath: current.path)[.size]) as? NSNumber)?.uint64Value ?? 0
                if size > 0 && size + UInt64(data.count) > self.maximumBytes {
                    for index in stride(from: self.archiveCount, through: 1, by: -1) {
                        let destination = self.root.appendingPathComponent("events.\(index).jsonl")
                        let source = index == 1 ? current : self.root.appendingPathComponent("events.\(index - 1).jsonl")
                        if fm.fileExists(atPath: destination.path) {
                            if index == self.archiveCount {
                                let marker = self.root.appendingPathComponent("last-overwrite.txt")
                                try Data(String(Date().timeIntervalSince1970).utf8).write(to: marker, options: .atomic)
                            }
                            try fm.removeItem(at: destination)
                        }
                        if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: destination) }
                    }
                }
                if !fm.fileExists(atPath: current.path) { guard fm.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) } }
                let file = try FileHandle(forWritingTo: current); defer { try? file.close() }
                try file.seekToEnd(); try file.write(contentsOf: data)
            } catch { self.lastWriteError = error }
        }
    }

    /// Retained events within the requested time window, oldest first; no category filtering.
    func snapshot(since cutoff: Date = Date().addingTimeInterval(-24 * 3600)) throws -> Data {
        try queue.sync {
            if let lastWriteError { throw lastWriteError }
            let marker = root.appendingPathComponent("last-overwrite.txt")
            let overwritten = (try? String(contentsOf: marker, encoding: .utf8)).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            let metadata: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "component": "diagnostics", "event": "snapshot", "fields": ["windowHours": 24, "retainedFileLimit": archiveCount + 1, "fileSizeLimitBytes": maximumBytes, "possiblyTruncated": overwritten.map { $0 >= cutoff } ?? false]]
            var result = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]); result.append(10)
            for index in stride(from: archiveCount, through: 0, by: -1) {
                let file = root.appendingPathComponent(index == 0 ? "events.jsonl" : "events.\(index).jsonl")
                if FileManager.default.fileExists(atPath: file.path) {
                    let source = try Data(contentsOf: file)
                    let formatter = ISO8601DateFormatter()
                    for line in source.split(separator: 10, omittingEmptySubsequences: true) {
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        let timestamp: Date?
                        if let value = object["timestamp"] as? TimeInterval { timestamp = Date(timeIntervalSince1970: value) }
                        else if let value = object["time"] as? String { timestamp = formatter.date(from: value) }
                        else { timestamp = nil }
                        guard let timestamp else { throw CocoaError(.fileReadCorruptFile) }
                        if timestamp >= cutoff { result.append(contentsOf: line); result.append(10) }
                    }
                }
            }
            return result
        }
    }
}
