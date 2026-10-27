import Foundation
import Darwin

struct LiveTranscriptEvent: Decodable, Sendable {
    let type: String
    let text: String
    let start: Double
    let end: Double
}

/// 管道写入与模型推理都在独立队列/进程，不阻塞录音队列或主线程。
final class LiveTranscriptionSession: @unchecked Sendable {
    var onEvent: ((LiveTranscriptEvent) -> Void)?
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "com.byering.cohear.live-input", qos: .userInitiated)
    private let reader = DispatchQueue(label: "com.byering.cohear.live-output", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var queuedSamples = 0
    private var closing = false
    private var stopped = false
    private var emittedFailure = false
    private var completions: [CheckedContinuation<Void, Never>] = []
    private var directory: URL?
    private var log: FileHandle?

    func start(model: URL, executable: URL, language: String) throws {
        lock.lock()
        let alreadyStarted = process != nil || stopped
        lock.unlock()
        guard !alreadyStarted else { throw NSError(domain: "CoHear.LiveSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "实时识别会话已启动或结束，请创建新会话。"]) }
        // 子进程退出时Foundation管道写应成为可处理的EPIPE，而不是终止录音应用。
        signal(SIGPIPE, SIG_IGN)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CoHear-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let logURL = directory.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try FileHandle(forWritingTo: logURL)
        let incoming = Pipe(), outgoing = Pipe()
        let child = Process()
        child.executableURL = executable; child.arguments = [model.path, language]
        child.standardInput = incoming; child.standardOutput = outgoing; child.standardError = log
        input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading; process = child
        child.terminationHandler = { [weak self] child in
            self?.reader.async { [weak self] in self?.complete(status: child.terminationStatus) }
        }
        do { try child.run() }
        catch { complete(status: 1); throw error }
        // 仅子进程持有读端/写端，保证退出和EOF能被对端识别。
        try? incoming.fileHandleForReading.close()
        try? outgoing.fileHandleForWriting.close()
        let handle = outgoing.fileHandleForReading
        reader.async { [weak self] in
            var pending = Data()
                while true {
                    // read(upToCount:)在部分Foundation实现会等满请求长度，稀疏JSON事件必须立即读取可用字节。
                    let data = handle.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    guard pending.count <= 1_048_576 else { self?.fail("实时识别响应异常"); break }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: newline)
                        if let event = try? JSONDecoder().decode(LiveTranscriptEvent.self, from: line) { self?.onEvent?(event) }
                        pending.removeSubrange(...newline)
                    }
                }
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        guard !closing, !stopped else { lock.unlock(); return }
        guard samples.count <= 64_000, queuedSamples + samples.count <= 16_000 * 5 else {
            lock.unlock(); fail("实时识别速度落后于录音，预览已停止；完整音频仍在录制"); return
        }
        queuedSamples += samples.count
        lock.unlock()
        writer.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.queuedSamples -= samples.count; self.lock.unlock() }
            self.lock.lock(); let active = !self.stopped; let handle = self.input; self.lock.unlock()
            guard active, let handle else { return }
            var count = UInt32(samples.count).littleEndian
            var data = withUnsafeBytes(of: &count) { Data($0) }
            samples.withUnsafeBytes { data.append(contentsOf: $0) }
            do { try handle.write(contentsOf: data) }
            catch { self.fail("实时识别引擎连接已中断；完整音频仍在录制") }
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopped { lock.unlock(); continuation.resume(); return }
            completions.append(continuation)
            if closing { lock.unlock(); return }
            closing = true
            lock.unlock()
            writer.async { [weak self] in
                guard let self else { return }
                try? self.input?.close() // EOF触发尾段识别。
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.fail("实时识别尾段处理超时；完整录音仍可转录")
            }
        }
    }

    func cancel() {
        lock.lock()
        if stopped { lock.unlock(); return }
        closing = true; stopped = true
        let child = process; let waiters = completions; completions.removeAll()
        lock.unlock()
        if let child, child.isRunning { child.terminate() }
        waiters.forEach { $0.resume() }
    }

    private func fail(_ message: String) {
        lock.lock()
        guard !emittedFailure, !stopped else { lock.unlock(); return }
        emittedFailure = true
        lock.unlock()
        onEvent?(LiveTranscriptEvent(type: "error", text: message, start: 0, end: 0))
        cancel()
    }
    private func complete(status: Int32) {
        lock.lock()
        let expected = stopped || emittedFailure
        stopped = true; closing = true
        let waiters = completions; completions.removeAll()
        lock.unlock()
        if status != 0 && !expected {
            onEvent?(LiveTranscriptEvent(type: "error", text: "实时引擎已退出；完整录音仍可转录", start: 0, end: 0))
        }
        writer.async { [weak self] in try? self?.input?.close() }
        try? log?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        waiters.forEach { $0.resume() }
    }
}
