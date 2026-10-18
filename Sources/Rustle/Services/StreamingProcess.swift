import Foundation
import Darwin

/// Drains both pipes concurrently and delivers complete UTF-8 lines before process exit.
final class StreamingProcess: @unchecked Sendable {
    struct Output { var status: Int32; var stdout: String; var stderr: String }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private func stop(_ task: Process?) {
        guard let task, task.isRunning else { return }
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if task.isRunning { kill(task.processIdentifier, SIGKILL) } }
    }
    private func cancel() { lock.lock(); cancelled = true; let task = process; lock.unlock(); stop(task) }

    func run(executable: URL, arguments: [String], timeout seconds: Double,
             line: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Output {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let task = Process(); let stdout = Pipe(); let stderr = Pipe()
                    task.executableURL = executable; task.arguments = arguments
                    task.standardOutput = stdout; task.standardError = stderr; task.standardInput = FileHandle.nullDevice
                    task.currentDirectoryURL = executable.deletingLastPathComponent()
                    var env = ProcessInfo.processInfo.environment
                    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                    task.environment = env
                    self.lock.lock(); self.process = task; let cancelledBeforeLaunch = self.cancelled; self.lock.unlock()
                    if cancelledBeforeLaunch { continuation.resume(throwing: CancellationError()); return }
                    do { try task.run() } catch { continuation.resume(throwing: error); return }
                    try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                    self.lock.lock(); let cancelAfterLaunch = self.cancelled; self.lock.unlock()
                    if cancelAfterLaunch { self.stop(task) }
                    let timer = DispatchWorkItem {
                        self.lock.lock(); self.timedOut = true; self.lock.unlock(); self.stop(task)
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
                    let drains = DispatchGroup(); let out = Tail(); let err = Tail()
                    for (pipe, tail) in [(stdout, out), (stderr, err)] {
                        drains.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            defer { try? pipe.fileHandleForReading.close(); drains.leave() }
                            var pending = Data()
                            var buffer = [UInt8](repeating: 0, count: 4096)
                            while true {
                                // FileHandle.read(upToCount:) may wait to fill its buffer on macOS pipes.
                                // POSIX read returns the available bytes immediately, keeping progress live.
                                let count = buffer.withUnsafeMutableBytes { Darwin.read(pipe.fileHandleForReading.fileDescriptor, $0.baseAddress!, $0.count) }
                                if count < 0 && errno == EINTR { continue }
                                if count <= 0 { break }
                                let data = Data(buffer.prefix(count))
                                tail.append(data); pending.append(data)
                                while let boundary = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                                    let text = String(decoding: pending[..<boundary], as: UTF8.self)
                                    pending.removeSubrange(...boundary)
                                    if !text.isEmpty { line(text) }
                                }
                                // Bound malformed lines as well as retained diagnostics.
                                if pending.count > 262_144 { pending.removeAll(keepingCapacity: true) }
                            }
                            if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
                        }
                    }
                    task.waitUntilExit(); drains.wait(); timer.cancel()
                    self.lock.lock(); let cancelled = self.cancelled; let timedOut = self.timedOut; self.process = nil; self.lock.unlock()
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                    else if timedOut { continuation.resume(throwing: ProcessingFailure.message("处理超时，请检查网络或尝试较小的模型。")) }
                    else { continuation.resume(returning: Output(status: task.terminationStatus, stdout: out.text, stderr: err.text)) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    private final class Tail: @unchecked Sendable {
        // Written by exactly one drain worker, read after DispatchGroup completion.
        private var data = Data()
        func append(_ bytes: Data) { data.append(bytes); if data.count > 262_144 { data = Data(data.suffix(262_144)) } }
        var text: String { String(decoding: data, as: UTF8.self) }
    }
}
