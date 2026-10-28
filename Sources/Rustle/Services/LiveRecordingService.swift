import AVFoundation
import Foundation

struct LiveAudioChunk: Sendable {
    let url: URL
    let start: TimeInterval
    let duration: TimeInterval

    func offsetting(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.compactMap { segment in
            guard segment.start.isFinite, segment.duration.isFinite, segment.start >= 0,
                  segment.start < duration, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var segment = segment
            segment.duration = max(0, min(segment.duration, duration - segment.start))
            segment.start += start
            return segment
        }
    }
}

struct LiveRecordingProgress: Sendable {
    var duration: TimeInterval
    var level: Double
}

struct LiveRecordingSession {
    enum Phase { case preparing, recording, finishing }
    let id: UUID
    let provider: TranscriptionProvider
    var phase: Phase = .preparing
    var duration: TimeInterval = 0
    var transcribedDuration: TimeInterval = 0
    var level: Double = 0

    var detail: String {
        switch phase {
        case .preparing: return "正在检查转写环境与麦克风权限…"
        case .recording:
            if transcribedDuration > 0 { return "已转写至 \(transcribedDuration.timestamp) · 每 5 秒提交一段" }
            return duration >= 5 ? "正在识别首段音频，录音仍在继续…" : "正在聆听 · 首段采集满 5 秒后开始识别"
        case .finishing: return "录音已保存，正在完成剩余转写 · 已处理至 \(transcribedDuration.timestamp)"
        }
    }
}

@MainActor
protocol LiveRecordingCapturing: AnyObject {
    func requestPermission() async -> Bool
    func start(in directory: URL, progress: @escaping @Sendable (LiveRecordingProgress) -> Void) throws -> AsyncThrowingStream<LiveAudioChunk, Error>
    @discardableResult func stop() -> TimeInterval
}

@MainActor
final class LiveRecordingService: LiveRecordingCapturing {
    private var engine: AVAudioEngine?
    private var writer: LiveAudioWriter?
    private var configurationObserver: NSObjectProtocol?

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(in directory: URL, progress: @escaping @Sendable (LiveRecordingProgress) -> Void) throws -> AsyncThrowingStream<LiveAudioChunk, Error> {
        guard engine == nil else { throw ProcessingFailure.message("已有录音正在进行。") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw ProcessingFailure.message("麦克风不可用，请在系统设置中检查声音输入设备。")
        }
        let (stream, continuation) = AsyncThrowingStream<LiveAudioChunk, Error>.makeStream()
        let writer = try LiveAudioWriter(directory: directory, format: format, continuation: continuation, progress: progress)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in writer.append(buffer) }
        do { engine.prepare(); try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            writer.finish(throwing: error)
            throw ProcessingFailure.message("无法启动麦克风，请检查输入设备与麦克风权限。")
        }
        self.writer = writer
        self.engine = engine
        continuation.onTermination = { [weak self, weak engine] _ in
            Task { @MainActor in
                // An old stream must never stop a newer recording session.
                if let engine, self?.engine === engine { self?.stop() }
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            writer.finish(throwing: ProcessingFailure.message("音频输入设备发生变化，录音已停止。请检查麦克风后重新开始。"))
        }
        return stream
    }

    @discardableResult func stop() -> TimeInterval {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
        let duration = writer?.finish() ?? 0
        writer = nil
        return duration
    }
}

/// The tap and stop operation share one lock. Files are closed before their
/// URLs enter the stream, and capture memory stays bounded to the tap buffer.
final class LiveAudioWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let format: AVAudioFormat
    private let interval: TimeInterval
    private let continuation: AsyncThrowingStream<LiveAudioChunk, Error>.Continuation
    private let progress: @Sendable (LiveRecordingProgress) -> Void
    private var recording: AVAudioFile?
    private var chunk: AVAudioFile?
    private var chunkURL: URL?
    private var totalFrames: AVAudioFramePosition = 0
    private var chunkStartFrame: AVAudioFramePosition = 0
    private var chunkIndex = 0
    private var lastProgress: TimeInterval = -1
    private var finished = false

    init(directory: URL, format: AVAudioFormat, interval: TimeInterval = 5,
         continuation: AsyncThrowingStream<LiveAudioChunk, Error>.Continuation,
         progress: @escaping @Sendable (LiveRecordingProgress) -> Void) throws {
        self.directory = directory.appendingPathComponent("LiveChunks", isDirectory: true)
        self.format = format
        self.interval = max(0.1, interval)
        self.continuation = continuation
        self.progress = progress
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        recording = try AVAudioFile(forWriting: directory.appendingPathComponent("microphone.caf"), settings: format.settings,
                                    commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, buffer.frameLength > 0 else { return }
        do {
            if chunk == nil {
                let url = directory.appendingPathComponent("\(chunkIndex).caf")
                chunk = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                chunkURL = url
                chunkStartFrame = totalFrames
                chunkIndex += 1
            }
            try recording?.write(from: buffer)
            try chunk?.write(from: buffer)
            totalFrames += AVAudioFramePosition(buffer.frameLength)
            let duration = Double(totalFrames) / format.sampleRate
            if duration - lastProgress >= 0.2 {
                lastProgress = duration
                progress(.init(duration: duration, level: Self.level(of: buffer)))
            }
            if Double(totalFrames - chunkStartFrame) / format.sampleRate >= interval { emitChunk() }
        } catch { close(throwing: ProcessingFailure.message("录音保存失败，请检查磁盘空间和目录权限。")) }
    }

    @discardableResult func finish(throwing error: Error? = nil) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        if !finished { close(throwing: error) }
        return Double(totalFrames) / format.sampleRate
    }

    private func close(throwing error: Error?) {
        finished = true
        emitChunk()
        recording = nil
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }

    private func emitChunk() {
        // Releasing the AVAudioFile finalizes its header before ASR opens it.
        chunk = nil
        guard let url = chunkURL else { return }
        chunkURL = nil
        let duration = Double(totalFrames - chunkStartFrame) / format.sampleRate
        if duration > 0 { continuation.yield(.init(url: url, start: Double(chunkStartFrame) / format.sampleRate, duration: duration)) }
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        var power: Double = 0
        if buffer.format.isInterleaved {
            for sample in 0..<(count * Int(buffer.format.channelCount)) { let value = Double(channels[0][sample]); power += value * value }
        } else {
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<count { let value = Double(channels[channel][frame]); power += value * value }
            }
        }
        let rms = sqrt(power / Double(max(1, count * Int(buffer.format.channelCount))))
        return max(0, min(1, (20 * log10(max(rms, 0.00001)) + 60) / 60))
    }
}
