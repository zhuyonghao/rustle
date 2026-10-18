import Foundation

final class HTTPFileTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) -> Void
    private let maximumBytes: Int64
    private let isAllowedURL: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var tooLarge = false
    private var lastReport = Date.distantPast
    private let stagingURL: URL
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var result: Result<HTTPURLResponse, Error>?
    private var transferSession: URLSession?
    private var transferTask: URLSessionDownloadTask?
    private var savedFile = false
    private var fileError: Error?
    var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return tooLarge }
    init(stagingURL: URL, maximumBytes: Int64, isAllowedURL: @escaping @Sendable (URL) -> Bool, progress: @escaping @Sendable (Int64, Int64) -> Void) { self.stagingURL = stagingURL; self.maximumBytes = maximumBytes; self.isAllowedURL = isAllowedURL; self.progress = progress }

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> HTTPURLResponse {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result); return }
                self.continuation = continuation
                lock.unlock()
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                lock.lock()
                let done = result != nil
                if !done { transferSession = session; transferTask = task }
                lock.unlock()
                if done { session.invalidateAndCancel() }
                else { task.resume() }
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    private func finish(_ outcome: Result<HTTPURLResponse, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let continuation = self.continuation; self.continuation = nil
        let session = transferSession; transferSession = nil; transferTask = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: outcome)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move synchronously while URLSession's temporary file is valid. The lock
        // prevents cancellation cleanup racing with a late download callback.
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return }
        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
            savedFile = true
            progress(downloadTask.countOfBytesReceived, downloadTask.countOfBytesExpectedToReceive)
        }
        catch { fileError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let localError = fileError; let saved = savedFile; lock.unlock()
        if let error = localError ?? error { finish(.failure(error)) }
        else if let response = task.response as? HTTPURLResponse, saved { finish(.success(response)) }
        else { finish(.failure(URLError(.badServerResponse))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { tooLarge = true; lock.unlock(); downloadTask.cancel(); return }
        let now = Date()
        let report = now.timeIntervalSince(lastReport) > 0.15 || totalBytesWritten == totalBytesExpectedToWrite
        if report { lastReport = now }; lock.unlock()
        if report { progress(totalBytesWritten, totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, isAllowedURL(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
}
