import CryptoKit
import Foundation

final class WhisperModelDownloader {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func download(_ model: WhisperModelDefinition, from url: URL, directory: URL,
                  progress: @escaping @Sendable (ModelDownloadUpdate) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        guard WhisperDownloadSource.isAllowed(url), directory.isFileURL else { throw ProcessingFailure.message("模型下载地址或保存目录无效。") }
        // Validate catalog filenames before creating any files.
        _ = try WhisperDownloadSource.huggingFace.url(for: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let stage = directory.appendingPathComponent(".\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: stage) }
        let observer = HTTPFileTransfer(stagingURL: stage, maximumBytes: 4_000_000_000, isAllowedURL: { WhisperDownloadSource.isAllowed($0) }) { received, total in
            progress(.downloading(received: received, total: total))
        }
        let http: HTTPURLResponse
        do { http = try await observer.run(request, configuration: session.configuration) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled && !observer.exceededLimit { throw CancellationError() }
            if observer.exceededLimit { throw ProcessingFailure.message("下载文件超过 4 GB，已停止下载。请选择兼容的 GGML 模型。") }
            if (error as NSError).domain == NSCocoaErrorDomain { throw ProcessingFailure.message("无法保存模型文件，请检查磁盘空间与目录权限。") }
            throw ProcessingFailure.message("无法连接下载源或连接中断，可换一个下载源后重试。")
        }
        try Task.checkCancellation()
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 { throw ProcessingFailure.message("此下载源没有该模型（404），请切换下载源。") }
            throw ProcessingFailure.message("下载源返回 HTTP \(http.statusCode)，请切换下载源或稍后重试。")
        }
        guard !(http.mimeType ?? "").contains("html") else { throw ProcessingFailure.message("下载源返回了网页，请使用模型文件的下载地址。") }
        progress(.verifying)
        return try await Self.installVerifiedFile(stage, model: model, directory: directory)
    }

    static func checksum(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = Insecure.SHA1()
        while true {
            try Task.checkCancellation()
            let block = try handle.read(upToCount: 1_048_576) ?? Data()
            if block.isEmpty { break }
            hash.update(data: block)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func installVerifiedFile(_ staging: URL, model: WhisperModelDefinition, directory: URL) async throws -> URL {
        _ = try WhisperDownloadSource.huggingFace.url(for: model)
        guard directory.isFileURL, staging.isFileURL, model.sha1.count == 40,
              model.sha1.allSatisfy(\.isHexDigit) else { throw ProcessingFailure.message("模型校验信息或本地目录无效。") }
        let size = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4_000_000_000 else { throw ProcessingFailure.message("模型文件为空或异常过大，未安装。") }
        guard try await checksum(of: staging) == model.sha1.lowercased() else {
            throw ProcessingFailure.message("模型校验未通过，文件可能不完整或与所选模型不一致。现有模型已保留，请切换下载源重试。")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(model.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        return destination
    }
}

