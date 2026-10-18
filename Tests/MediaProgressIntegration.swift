import Foundation

private final class LiveReports: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double] = []
    private var lastTitle = ""
    func receive(_ update: ProcessingProgress) {
        lock.lock(); defer { lock.unlock() }
        if let fraction = update.fraction { fractions.append(fraction) }
        if lastTitle != update.title || update.fraction != nil {
            print("\(update.title) \(update.percentLabel ?? "") · \(update.detail)")
            fflush(stdout)
        }
        lastTitle = update.title
    }
    var sawIntermediate: Bool { lock.lock(); defer { lock.unlock() }; return fractions.contains { $0 > 0 && $0 < 1 } }
}

@main struct MediaProgressIntegration {
    static func main() async throws {
        guard CommandLine.arguments.count > 1, let url = URL(string: CommandLine.arguments[1]) else { fatalError("Pass a media URL") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent(".runtime/progress-validation/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = LiveReports()
        let media = try await ProcessingEngine().prepareMedia(from: url, destinationDirectory: directory) { download.receive($0) }
        print("媒体标题：\(media.title)")
        guard download.sawIntermediate else { fatalError("No intermediate download progress") }
        let asr = LiveReports()
        var configuration = ProcessingConfiguration()
        configuration.whisperExecutablePath = root.appendingPathComponent(".runtime/whisper/bin/whisper-cli").path
        configuration.whisperModelPath = root.appendingPathComponent(".runtime/models/ggml-small.bin").path
        let result = try await ProcessingEngine().transcribe(url: media.url, configuration: configuration) { asr.receive($0) }
        guard asr.sawIntermediate, !result.segments.isEmpty else { fatalError("No transcription/progress") }
        print("PASS: real URL download + local small ASR; \(result.segments.count) segments, \(result.duration.timestamp)")
    }
}
