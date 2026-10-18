import Foundation

@main struct ModelDownloadIntegration {
    static func main() async {
        do {
            let source: WhisperDownloadSource
            switch CommandLine.arguments.dropFirst().first ?? "hf-mirror" {
            case "huggingface": source = .huggingFace
            case "hf-mirror": source = .hfMirror
            case "custom": source = .custom
            default: throw ProcessingFailure.message("下载源须为 huggingface、hf-mirror 或 custom。")
            }
            let name = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "tiny"
            guard let model = WhisperModelDefinition.catalog.first(where: { $0.id == name }) else { throw ProcessingFailure.message("模型名称无效。") }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".runtime/download-validation")
            let fallback = source.fallbackSources(enabled: ProcessInfo.processInfo.environment["RUSTLE_MODEL_FALLBACK"] != "0")
            for (index, candidate) in fallback.enumerated() {
                do {
                    report("下载源：\(candidate.title) · \(model.title) · \(model.sizeLabel)")
                    let progress = ModelDownloadProgressLog()
                    let url = try candidate.url(for: model, customAddress: ProcessInfo.processInfo.environment["RUSTLE_MODEL_URL"] ?? "")
                    let installed = try await WhisperModelDownloader().download(model, from: url, directory: directory) { update in progress.record(update) }
                    guard progress.receivedBytes > 0 else { throw ProcessingFailure.message("下载未报告实际字节进度。") }
                    let bytes = try installed.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    report("PASS 真实模型下载、字节进度和官方 SHA-1 校验：\(candidate.title)，\(bytes) 字节")
                    return
                } catch {
                    report("\(candidate.title) 未成功：\(error.localizedDescription)")
                    if index == fallback.count - 1 { throw error }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func report(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
}

private final class ModelDownloadProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var received: Int64 = 0
    private var bucket: Int64 = -1
    var receivedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return received }
    func record(_ update: ModelDownloadUpdate) {
        lock.lock(); defer { lock.unlock() }
        switch update {
        case .verifying: ModelDownloadIntegration.report("下载完成，正在校验…")
        case .downloading(let bytes, _):
            received = bytes
            if bytes / 10_000_000 != bucket {
                bucket = bytes / 10_000_000
                ModelDownloadIntegration.report("已下载 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            }
        }
    }
}
