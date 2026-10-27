import CryptoKit
import Foundation

/// URLSession下载写入磁盘；主线程只接收进度，SHA校验分块执行。
final class OptionalModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var lastProgressUpdate = Date.distantPast
    private let destination: URL
    private let expectedBytes: Int64
    let onProgress: @Sendable (Int64) -> Void
    init(destination: URL, expectedBytes: Int64, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination; self.expectedBytes = expectedBytes; self.onProgress = onProgress
    }
    func fetch(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 40; config.timeoutIntervalForResource = 24 * 3600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url); self.task = task
                lock.unlock(); task.resume()
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil
        let session = self.session; self.session = nil; task = nil; lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes { downloadTask.cancel(); finish(.failure(OptionalModelError.message("模型文件超过清单声明大小，下载已停止。"))); return }
        if totalBytesWritten == expectedBytes || Date().timeIntervalSince(lastProgressUpdate) >= 0.1 {
            lastProgressUpdate = Date(); onProgress(totalBytesWritten)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let cancelled = cancelled; lock.unlock()
        guard !cancelled else { return }
        guard let http = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(OptionalModelError.message("模型下载响应无效。"))); return
        }
        guard http.statusCode == 200 else { finish(.failure(OptionalModelError.http(http.statusCode))); return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == expectedBytes else { throw OptionalModelError.message("模型下载不完整，文件未启用。") }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

enum OptionalModelIntegrity {
    static func verify(_ url: URL, file: OptionalModelFile) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value == file.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}
