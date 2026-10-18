import Foundation
@main struct LocalIntegration {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let environment = ProcessInfo.processInfo.environment
        var config = ProcessingConfiguration()
        config.provider = .whisperCpp
        config.whisperModelPath = environment["RUSTLE_WHISPER_MODEL"] ?? root.appendingPathComponent(".runtime/models/ggml-base.bin").path
        config.localeIdentifier = environment["RUSTLE_TEST_LANGUAGE"] ?? "en-US"
        config.whisperUseGPU = environment["RUSTLE_TEST_GPU"] == "1"
        let input = environment["RUSTLE_TEST_MEDIA"]
        var source = input.map { $0.hasPrefix("https://") ? URL(string: $0)! : URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".runtime/src/whisper.cpp/samples/jfk.wav")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("rustle-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if !source.isFileURL { source = try await ProcessingEngine().prepareMedia(from: source, destinationDirectory: temporary).url }
        let result = try await ProcessingEngine().transcribe(url: source, configuration: config)
        let text = result.segments.map(\.text).joined(separator: " ")
        guard text.lowercased().contains(environment["RUSTLE_EXPECT_TEXT"] ?? "country"), result.duration > 0, !result.segments.isEmpty else {
            throw NSError(domain: "RustleIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: "真实本地转写未匹配样例内容：\(text)"])
        }
        do {
            _ = try await ProcessingEngine().generateInsights(transcript: text, configuration: config)
            fatalError("未配置 API 时不能生成内容整理结果")
        } catch {
            guard error.localizedDescription.contains("内容整理 API Key") else { throw error }
        }
        print("PASS 本地 Whisper \(config.whisperUseGPU ? "GPU" : "CPU") 真实音频转写：\(result.duration.timestamp)，\(result.segments.count) 段")
        print(text)
        print("PASS 内容整理必须配置独立 API，本地转写保持离线")
    }
}
