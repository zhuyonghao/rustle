import Foundation

/// One decoder per HTTP request. Events and UTF-8 characters may span network packets.
struct ChatCompletionStream {
    private var pending = Data()
    private var eventLines: [String] = []
    private(set) var content = ""
    private(set) var isDone = false
    private var finishReason: String?

    mutating func append(_ data: Data) throws {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            var line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            try consume(String(decoding: line, as: UTF8.self))
        }
    }

    mutating func finish() throws -> Data {
        if !pending.isEmpty {
            try consume(String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .newlines))
            pending.removeAll()
        }
        try dispatchEvent()
        if finishReason == "length" { throw ProcessingFailure.outputTruncated }
        guard finishReason == "stop", !content.isEmpty else {
            throw ProcessingFailure.message("AI 内容未完整生成，请重试或更换模型。")
        }
        return try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
    }

    private mutating func consume(_ line: String) throws {
        if line.isEmpty { try dispatchEvent() }
        else if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            eventLines.append(value)
        }
        // Ignore SSE comments, IDs, event names and keep-alives.
    }

    private mutating func dispatchEvent() throws {
        guard !eventLines.isEmpty, !isDone else { eventLines.removeAll(); return }
        let event = eventLines.joined(separator: "\n")
        eventLines.removeAll()
        if event == "[DONE]" { isDone = true; return }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { var content: String?; var refusal: String? }
                var index: Int?
                var delta: Delta
                var finish_reason: String?
            }
            var choices: [Choice]
        }
        let chunk: Chunk
        do { chunk = try JSONDecoder().decode(Chunk.self, from: Data(event.utf8)) }
        catch { throw ProcessingFailure.message("总结服务返回的流式格式不正确，请检查 API 兼容性。") }
        guard let choice = chunk.choices.first(where: { ($0.index ?? 0) == 0 }) else { return }
        guard choice.delta.refusal == nil else { throw ProcessingFailure.message("AI 未生成此内容，请重试或更换模型。") }
        if let text = choice.delta.content { content += text }
        if let reason = choice.finish_reason { finishReason = reason }
        if finishReason == "length" { throw ProcessingFailure.outputTruncated }
    }

    /// Readable, provisional text from an unfinished JSON object. Never persisted as a result.
    static func preview(_ source: String) -> String {
        let characters = Array(source)
        var values: [String] = []
        var containers: [Character] = []
        var previous: Character = " "
        var index = 0
        while index < characters.count {
            let current = characters[index]
            guard current == "\"" else {
                if current == "{" || current == "[" { containers.append(current) }
                if current == "}" || current == "]" { _ = containers.popLast() }
                if !current.isWhitespace { previous = current }
                index += 1; continue
            }
            let isKey = containers.last == "{" && (previous == "{" || previous == ",")
            index += 1
            var encoded = "\""
            while index < characters.count {
                let character = characters[index]; index += 1
                if character == "\"" { break }
                if character == "\\" {
                    guard index < characters.count else { break }
                    let escape = characters[index]; index += 1
                    if escape == "u" {
                        guard index + 4 <= characters.count else { break }
                        encoded += "\\u" + String(characters[index..<index + 4]); index += 4
                    } else { encoded += "\\" + String(escape) }
                } else { encoded.append(character) }
            }
            previous = "\""
            if !isKey, let value = try? JSONDecoder().decode(String.self, from: Data((encoded + "\"").utf8)), !value.isEmpty {
                values.append(value)
            }
        }
        return values.joined(separator: "\n\n")
    }
}

/// Dedicated session and serial delegate queue per request: no request waits on another stream.
final class StreamingContentRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let output: @Sendable (String) -> Void
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var result: Result<(Data, URLResponse), Error>?
    private var transferSession: URLSession?
    private var deadline: DispatchWorkItem?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var decoder = ChatCompletionStream()
    private var isStream = false
    private var received = 0
    private var lastReport = Date.distantPast

    init(output: @escaping @Sendable (String) -> Void) { self.output = output }

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                transferSession = session
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
                deadline = timer
                let task = session.dataTask(with: request)
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + request.timeoutInterval, execute: timer)
                task.resume()
            }
        }, onCancel: { self.finish(.failure(CancellationError())) })
    }

    private func finish(_ outcome: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let continuation = continuation; self.continuation = nil
        let session = transferSession; transferSession = nil
        deadline?.cancel(); deadline = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: outcome)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        isStream = (200..<300).contains(self.response?.statusCode ?? 0) && response.mimeType?.lowercased() == "text/event-stream"
        let active = result == nil
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        do {
            received += data.count
            guard received <= 8_000_000 else { throw ProcessingFailure.message("AI 返回内容异常过长，请缩短内容后重试。") }
            var preview: String?
            var outcome: (Data, URLResponse)?
            if isStream {
                try decoder.append(data)
                let now = Date()
                if !decoder.content.isEmpty && (now.timeIntervalSince(lastReport) >= 0.05 || decoder.isDone) {
                    lastReport = now
                    preview = decoder.content
                }
                if decoder.isDone, let response { outcome = (try decoder.finish(), response) }
            } else { body.append(data) }
            lock.unlock()
            if let preview { output(preview) }
            if let outcome { finish(.success(outcome)) }
        } catch { lock.unlock(); finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        do {
            if let error { throw error }
            guard let response else { throw URLError(.badServerResponse) }
            let data = try isStream ? decoder.finish() : body
            let preview = isStream ? decoder.content : nil
            lock.unlock()
            if let preview { output(preview) }
            finish(.success((data, response)))
        } catch { lock.unlock(); finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
