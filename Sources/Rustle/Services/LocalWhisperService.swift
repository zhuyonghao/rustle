import Foundation
import AVFoundation
import Darwin

/// Offline ASR backed by the user's local whisper.cpp executable and GGML model.
/// AVFoundation converts media into bounded 16 kHz mono PCM WAV chunks; no network requests are made.
final class LocalWhisperService {
    private let files = FileManager.default

    static func resolveExecutable(_ configured: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let explicit = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return executableURL(explicit) }
        if let value = environment["RUSTLE_WHISPER_EXECUTABLE"], !value.isEmpty { return executableURL(value) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var candidates = [root.appendingPathComponent(".runtime/whisper/bin/whisper-cli").path]
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Whisper/whisper-cli").path) }
        candidates += ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli", "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cpp"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/whisper-cli" }
        return candidates.lazy.compactMap(executableURL).first
    }

    static func resolveModel(_ configured: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let explicit = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return modelURL(explicit) }
        if let value = environment["RUSTLE_WHISPER_MODEL"], !value.isEmpty { return modelURL(value) }
        return nil
    }

    private static func expandedURL(_ value: String) -> URL { URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL }
    private static func executableURL(_ value: String) -> URL? {
        let url = expandedURL(value)
        guard FileManager.default.isExecutableFile(atPath: url.path), (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }
    private static func modelURL(_ value: String) -> URL? {
        let url = expandedURL(value)
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? 0) > 0, FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    func transcribe(url: URL, configuration: ProcessingConfiguration, progress: @escaping @Sendable (ProcessingProgress) -> Void = { _ in }) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        guard url.isFileURL else { throw ProcessingFailure.message("本地 Whisper 需要先将媒体导入本地。") }
        guard let executable = Self.resolveExecutable(configuration.whisperExecutablePath) else {
            throw ProcessingFailure.message("未找到可运行的 whisper.cpp。请先运行本地模型安装脚本，或在设置中选择 whisper-cli 可执行文件。")
        }
        guard let model = Self.resolveModel(configuration.whisperModelPath) else {
            throw ProcessingFailure.message("尚未选择可用的本地 Whisper 模型。请在设置中选择模型，或下载后使用。")
        }
        let language = try Self.languageCode(configuration.localeIdentifier)
        if model.lastPathComponent.contains(".en."), language != "en", language != "auto" {
            throw ProcessingFailure.message("所选模型仅支持英语，请改用多语言模型（例如 ggml-base.bin），或将识别语言设置为英语。")
        }
        let asset = AVURLAsset(url: url)
        let duration: Double
        do {
            duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw ProcessingFailure.message("文件没有可识别的音轨。") }
        } catch let failure as ProcessingFailure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw ProcessingFailure.message("无法读取媒体音轨，请转换为 MP3、M4A、WAV、MP4 或 MOV 后重试。") }
        let temporary = files.temporaryDirectory.appendingPathComponent("rustle-local-whisper-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temporary) }
        var segments: [TranscriptSegment] = []; var detectedLanguage = language
        var offset: Double = 0
        while offset < duration {
            try Task.checkCancellation()
            let chunkDuration = min(600, duration - offset)
            let wave = temporary.appendingPathComponent("chunk.wav")
            let prefix = temporary.appendingPathComponent("result")
            let output = prefix.appendingPathExtension("json")
            let chunkOffset = offset
            let chunkLabel = "第 \(Int(offset / 600) + 1)/\(Int(ceil(duration / 600))) 段"
            progress(.init(title: "正在提取音轨", fraction: 0, detail: chunkLabel))
            try await Self.exportWAV(from: url, start: offset, duration: chunkDuration, destination: wave) { fraction in
                progress(.init(title: "正在提取音轨", fraction: fraction, detail: chunkLabel))
            }
            let arguments = Self.arguments(model: model, wave: wave, outputPrefix: prefix, language: language, useGPU: configuration.whisperUseGPU)
            progress(.init(title: "正在加载本地 Whisper 模型", detail: "\(chunkLabel) · 等待模型开始识别"))
            let operation = WhisperProcessOperation()
            try await operation.run(executable: executable, arguments: arguments) { line in
                if let fraction = MediaProgressParser.whisper(line) {
                    progress(.transcription(offset: chunkOffset, chunkDuration: chunkDuration, duration: duration, fraction: fraction))
                }
            }
            try Task.checkCancellation()
            guard files.fileExists(atPath: output.path) else {
                throw ProcessingFailure.message("whisper.cpp 未生成 JSON 转写结果。请检查所选程序是否为支持 -oj 参数的 whisper-cli，并更新到兼容版本。")
            }
            let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard bytes > 0, bytes < 20_000_000 else { throw ProcessingFailure.message("本地模型输出为空或格式异常，请更换模型后重试。") }
            let result = try Self.parseOutput(Data(contentsOf: output), offset: offset, duration: chunkDuration)
            segments.append(contentsOf: result.segments.map { segment in
                var segment = segment
                segment.text = Self.normalizedText(segment.text, localeIdentifier: configuration.localeIdentifier)
                return segment
            })
            if !result.language.isEmpty { detectedLanguage = result.language }
            for file in [wave, output] { try? files.removeItem(at: file) }
            offset += chunkDuration
            progress(.init(title: "本地转写已完成分段", fraction: offset / duration, detail: "已处理 \(offset.timestamp) / \(duration.timestamp)"))
        }
        guard !segments.isEmpty else { throw ProcessingFailure.message("本地模型未识别到有效语音，请检查录音或尝试更大的多语言模型。") }
        return TranscriptionResult(segments: segments, duration: duration, language: detectedLanguage)
    }

    static func languageCode(_ identifier: String) throws -> String {
        if identifier.lowercased() == "auto" { return "auto" }
        let code = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard (2...3).contains(code.count), code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw ProcessingFailure.message("识别语言无效，请选择中文、英语或自动识别。")
        }
        return code
    }

    static func normalizedText(_ text: String, localeIdentifier: String) -> String {
        let locale = localeIdentifier.lowercased()
        if locale == "zh-cn" || locale == "zh-hans" {
            return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        }
        return text
    }

    static func arguments(model: URL, wave: URL, outputPrefix: URL, language: String, useGPU: Bool) -> [String] {
        var values = ["-m", model.path, "-f", wave.path, "-l", language, "-oj", "-pp", "-of", outputPrefix.path]
        if !useGPU { values.append("-ng") }
        return values
    }

    static func parseOutput(_ data: Data, offset: TimeInterval, duration: TimeInterval) throws -> TranscriptionResult {
        struct Payload: Decodable {
            struct Result: Decodable { var language: String? }
            struct Segment: Decodable { struct Offsets: Decodable { var from: Double; var to: Double }; var offsets: Offsets; var text: String }
            var result: Result?; var transcription: [Segment]
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw ProcessingFailure.message("本地 Whisper JSON 格式不兼容，请更新 whisper.cpp 后重试。") }
        guard offset.isFinite, offset >= 0, duration.isFinite, duration > 0,
              payload.transcription.allSatisfy({ $0.offsets.from.isFinite && $0.offsets.to.isFinite && $0.offsets.from >= 0 && $0.offsets.to >= $0.offsets.from && $0.offsets.from / 1000 <= duration + 1 }) else {
            throw ProcessingFailure.message("本地 Whisper 返回了无效的时间戳，请检查模型与程序版本。")
        }
        let segments = payload.transcription.compactMap { segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = min(segment.offsets.from / 1000, duration)
            let end = min(segment.offsets.to / 1000, duration)
            return TranscriptSegment(start: offset + start, duration: max(0, end - start), text: text)
        }
        return TranscriptionResult(segments: segments, duration: duration, language: payload.result?.language ?? "")
    }

    /// Writes a standard RIFF/WAVE stream without requiring FFmpeg or loading the whole track into memory.
    static func exportWAV(from url: URL, start: TimeInterval, duration: TimeInterval, destination: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ProcessingFailure.message("媒体没有可转换的音轨。") }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw ProcessingFailure.message("无法创建音频读取器，请换用兼容的音频格式。") }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16000), duration: CMTime(seconds: duration, preferredTimescale: 16000))
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProcessingFailure.message("此音轨无法转换为 Whisper 所需的 WAV 格式。") }
        reader.add(output)
        guard reader.startReading() else { throw ProcessingFailure.message("无法解码音轨，请将原始文件转换为 M4A 或 WAV 后重试。") }
        FileManager.default.createFile(atPath: destination.path, contents: Data(repeating: 0, count: 44))
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close(); if reader.status == .reading { reader.cancelReading() } }
        try handle.seekToEnd()
        var pcmBytes: UInt32 = 0
        var lastReport = Date.distantPast
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(buffer)
            guard length >= 0, UInt64(pcmBytes) + UInt64(length) < UInt64(UInt32.max - 36) else { throw ProcessingFailure.message("音频分段过长，无法生成 WAV 文件。") }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { pointer in CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: pointer.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw ProcessingFailure.message("读取音频采样失败，请重试。") }
            try handle.write(contentsOf: bytes); pcmBytes += UInt32(length)
            if Date().timeIntervalSince(lastReport) >= 0.15 {
                lastReport = Date(); progress(min(1, Double(pcmBytes) / 32000 / duration))
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed, pcmBytes > 0 else { throw ProcessingFailure.message("音轨转换未完成，请检查源文件是否损坏。") }
        var header = Data()
        func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
        func long(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { header.append(contentsOf: $0) } }
        header.append(Data("RIFF".utf8)); long(36 + pcmBytes); header.append(Data("WAVEfmt ".utf8)); long(16)
        word(1); word(1); long(16000); long(32000); word(2); word(16); header.append(Data("data".utf8)); long(pcmBytes)
        try handle.seek(toOffset: 0); try handle.write(contentsOf: header)
        progress(1)
    }
}

private final class WhisperProcessOperation {
    func run(executable: URL, arguments: [String], line: @escaping @Sendable (String) -> Void) async throws {
        let result: StreamingProcess.Output
        do { result = try await StreamingProcess().run(executable: executable, arguments: arguments, timeout: 1800, line: line) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as ProcessingFailure { throw failure }
        catch { throw ProcessingFailure.message("无法启动 whisper-cli，请检查执行权限、CPU 架构与所需动态库，或重新运行安装脚本。") }
        if result.status != 0 {
            let text = result.stderr.lowercased()
            let message: String
            if text.contains("failed to load model") || text.contains("invalid model") || text.contains("bad magic") || text.contains("failed to open") {
                message = "Whisper 模型无法加载，可能不完整或格式不兼容。请选择 whisper.cpp 的 GGML .bin 模型（如 ggml-base.bin），不要选择 safetensors 或 GGUF 文件。"
            } else if text.contains("dyld") || text.contains("library not loaded") {
                message = "whisper-cli 缺少动态库，请重新运行安装脚本，或选择完整安装的程序。"
            } else if text.contains("metal") || text.contains("gpu") {
                message = "本地 GPU 推理启动失败，请在设置中关闭 GPU 后重试，或更新 whisper.cpp。"
            } else {
                message = "本地 Whisper 转写失败，请检查模型与程序版本是否兼容，或关闭 GPU 后重试。"
            }
            throw ProcessingFailure.message(message)
        }
    }
}
