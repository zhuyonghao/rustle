import XCTest
import Foundation
@testable import Rustle

final class ContentStreamingTests: XCTestCase {
    override func tearDown() { PausedContentURLProtocol.reset(); super.tearDown() }

    func testSSEDecodesFragmentedUTF8CommentsMultipleDataLinesAndUsage() throws {
        var decoder = ChatCompletionStream()
        let text = #"{"summary":"中文🙂\n总结","keyPoints":["第一点"]}"#
        let first = try Self.event(text)
        // Deliberately split every UTF-8 character and every SSE boundary.
        for byte in Data(": keep-alive\r\nid: 7\r\nevent: message\r\n".utf8) + first {
            try decoder.append(Data([byte]))
        }
        XCTAssertEqual(decoder.content, text)
        try decoder.append(Data("data: {\"choices\":\n".utf8))
        try decoder.append(Data("data: [{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n".utf8))
        try decoder.append(Data("data: {\"choices\":[],\"usage\":{}}\n\ndata: [DONE]\n\n".utf8))
        XCTAssertTrue(decoder.isDone)
        let result = try JSONSerialization.jsonObject(with: decoder.finish()) as! [String: Any]
        let choices = result["choices"] as! [[String: Any]]
        XCTAssertEqual((choices[0]["message"] as? [String: String])?["content"], text)
        XCTAssertEqual(ChatCompletionStream.preview(text), "中文🙂\n总结\n\n第一点")
    }

    func testPreviewHandlesUnfinishedKeysValuesEscapesAndNestedArrays() {
        XCTAssertEqual(ChatCompletionStream.preview(#"{"summ"#), "")
        XCTAssertEqual(ChatCompletionStream.preview(#"{"summary":"逐字生成"#), "逐字生成")
        XCTAssertEqual(ChatCompletionStream.preview(#"{"summary":"他说：\"继续\"\n下一行","keyPoints":["要点一","要点"#), "他说：\"继续\"\n下一行\n\n要点一\n\n要点")
        XCTAssertEqual(ChatCompletionStream.preview(#"{"title":"主题","children":[{"title":"分支","children":[]}]}"#), "主题\n\n分支")
        XCTAssertEqual(ChatCompletionStream.preview(#"{"summary":"\u4e2d\u6587\u"#), "中文")
    }

    func testSSERejectsInterruptedTruncatedRefusedAndMalformedResponses() throws {
        var interrupted = ChatCompletionStream()
        try interrupted.append(Self.event(#"{"summary":"部分结果"#))
        XCTAssertThrowsError(try interrupted.finish())
        try interrupted.append(Data("data: [DONE]\n\n".utf8))
        XCTAssertThrowsError(try interrupted.finish())
        var truncated = ChatCompletionStream()
        XCTAssertThrowsError(try truncated.append(Self.event("partial", finishReason: "length"))) { error in
            guard case ProcessingFailure.outputTruncated = error else { XCTFail("Expected truncation"); return }
        }
        var refused = ChatCompletionStream()
        XCTAssertThrowsError(try refused.append(Data("data: {\"choices\":[{\"delta\":{\"refusal\":\"private provider text\"}}]}\n\n".utf8))) { error in
            XCTAssertFalse(error.localizedDescription.contains("private provider text"))
        }
        var malformed = ChatCompletionStream()
        XCTAssertThrowsError(try malformed.append(Data("data: not JSON\n\n".utf8)))
    }

    @MainActor
    func testIndependentStreamsShowPartialOutputAndMergeResultsAcrossFeaturesAndRecords() async throws {
        let (store, directory, session) = makeStore()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let first = recording("第一份原文")
        let second = recording("第二份原文")
        store.recordings = [first, second]; store.selectedID = first.id
        store.generateInsight(.overview)
        store.generateInsight(.mindMap)
        store.generateInsight(.overview) // Suppress only duplicate requests for this feature.
        store.selectedID = second.id
        store.generateInsight(.tasks)
        try await waitUntil { PausedContentURLProtocol.requests.count == 3 }
        XCTAssertEqual(store.insightGenerations.count, 3)
        let overview = PausedContentURLProtocol.request(.overview, source: first.transcript)!
        let map = PausedContentURLProtocol.request(.mindMap, source: first.transcript)!
        let tasks = PausedContentURLProtocol.request(.tasks, source: second.transcript)!
        overview.send(try Self.event(#"{"summary":"正在流式显示"#))
        try await waitUntil { store.insightGeneration(for: first.id, feature: .overview)?.preview == "正在流式显示" }
        XCTAssertNil(store.recordings[0].contentInsights?.overview)
        map.send(try Self.event(#"{"title":"并发导图","children":[]}"#, finishReason: "stop") + Self.done)
        try await waitUntil { store.recordings[0].contentInsights?.mindMap?.title == "并发导图" }
        XCTAssertNotNil(store.insightGeneration(for: first.id, feature: .overview))
        overview.send(try Self.event(#"完成","keyPoints":[]}"#, finishReason: "stop") + Self.done)
        tasks.send(try Self.event(#"{"tasks":[{"title":"独立待办","owner":null,"dueDate":null}]}"#, finishReason: "stop") + Self.done)
        try await waitUntil { !store.generatingInsights }
        XCTAssertEqual(PausedContentURLProtocol.requests.count, 3)
        XCTAssertEqual(store.recordings[0].contentInsights?.overview?.summary, "正在流式显示完成")
        XCTAssertEqual(store.recordings[0].contentInsights?.mindMap?.title, "并发导图")
        XCTAssertEqual(store.recordings[1].contentInsights?.tasks?.first?.title, "独立待办")
        let reloaded = AppStore(directory: directory, initialConfiguration: configuration())
        XCTAssertEqual(reloaded.recordings, store.recordings)
    }

    @MainActor
    func testCancellationAndRetryIgnoreOldStreamWithoutCancellingOtherFeatures() async throws {
        let (store, directory, session) = makeStore()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let record = recording("原文")
        store.recordings = [record]; store.selectedID = record.id
        store.generateInsight(.overview); store.generateInsight(.mindMap)
        try await waitUntil { PausedContentURLProtocol.requests.count == 2 }
        let old = PausedContentURLProtocol.request(.overview, source: record.transcript)!
        let map = PausedContentURLProtocol.request(.mindMap, source: record.transcript)!
        old.send(try Self.event(#"{"summary":"旧结果"#))
        try await waitUntil { store.insightGeneration(for: record.id, feature: .overview)?.preview == "旧结果" }
        store.cancelInsightGeneration(.overview)
        XCTAssertNil(store.insightGeneration(for: record.id, feature: .overview))
        XCTAssertNotNil(store.insightGeneration(for: record.id, feature: .mindMap))
        store.generateInsight(.overview)
        try await waitUntil { PausedContentURLProtocol.requests.count == 3 }
        let retry = PausedContentURLProtocol.request(.overview, source: record.transcript)!
        old.send(try Self.event(#"过期","keyPoints":[]}"#, finishReason: "stop") + Self.done)
        retry.send(try Self.event(#"{"summary":"新结果","keyPoints":[]}"#, finishReason: "stop") + Self.done)
        map.send(try Self.event(#"{"title":"仍在运行的导图","children":[]}"#, finishReason: "stop") + Self.done)
        try await waitUntil { !store.generatingInsights }
        XCTAssertEqual(store.selected?.contentInsights?.overview?.summary, "新结果")
        XCTAssertEqual(store.selected?.contentInsights?.mindMap?.title, "仍在运行的导图")
        XCTAssertNil(store.selected?.contentInsights?.errors)
    }

    @MainActor
    func testEditingAndDeletionCancelOnlyAffectedRecordingAndClearPreviews() async throws {
        let (store, directory, session) = makeStore()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let first = recording("编辑前原文"); let second = recording("其他记录")
        store.recordings = [first, second]; store.selectedID = second.id
        store.generateInsight(.tasks)
        store.selectedID = first.id
        store.generateInsight(.overview); store.generateInsight(.mindMap)
        try await waitUntil { PausedContentURLProtocol.requests.count == 3 }
        store.editSegment(first.segments[0].id, text: "编辑后原文")
        XCTAssertEqual(store.insightGenerations.count, 1)
        XCTAssertEqual(store.selected?.transcript, "编辑后原文")
        XCTAssertNil(store.selected?.contentInsights)
        store.generateInsight(.overview)
        try await waitUntil { PausedContentURLProtocol.requests.count == 4 }
        await store.deleteRecording(first.id)
        XCTAssertEqual(store.insightGenerations.count, 1)
        let tasks = PausedContentURLProtocol.request(.tasks, source: second.transcript)!
        tasks.send(try Self.event(#"{"tasks":[]}"#, finishReason: "stop") + Self.done)
        try await waitUntil { !store.generatingInsights }
        XCTAssertEqual(store.recordings.map(\.id), [second.id])
        XCTAssertEqual(store.selected?.contentInsights?.tasks, [])
    }

    @MainActor
    func testStreamFailureKeepsPreviousResultAndDoesNotBlockOtherRequest() async throws {
        let (store, directory, session) = makeStore()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        var record = recording("原文")
        record.contentInsights = ContentInsights(overview: ContentOverview(summary: "已有摘要", keyPoints: []))
        store.recordings = [record]; store.selectedID = record.id
        store.generateInsight(.overview); store.generateInsight(.tasks)
        try await waitUntil { PausedContentURLProtocol.requests.count == 2 }
        PausedContentURLProtocol.request(.overview, source: record.transcript)!.send(try Self.event(#"{"summary":"未完成"#), complete: true)
        try await waitUntil { store.insightGeneration(for: record.id, feature: .overview) == nil }
        XCTAssertEqual(store.selected?.contentInsights?.overview?.summary, "已有摘要")
        XCTAssertNotNil(store.selected?.contentInsights?.errors?["overview"])
        XCTAssertNotNil(store.insightGeneration(for: record.id, feature: .tasks))
        PausedContentURLProtocol.request(.tasks, source: record.transcript)!.send(try Self.event(#"{"tasks":[]}"#, finishReason: "stop") + Self.done)
        try await waitUntil { !store.generatingInsights }
        XCTAssertEqual(store.selected?.contentInsights?.tasks, [])
        XCTAssertEqual(store.selected?.contentInsights?.overview?.summary, "已有摘要")
    }

    @MainActor
    func testFollowUpAndSubtitleTranslationStreamAtTheSameTime() async throws {
        let (store, directory, session) = makeStore()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let record = recording("小林周五提交设计稿")
        store.recordings = [record]; store.selectedID = record.id
        store.generateInsight(.followUp, question: "谁负责？")
        store.generateInsight(.translation, language: .english)
        try await waitUntil { PausedContentURLProtocol.requests.count == 2 }
        let answer = PausedContentURLProtocol.requests.first { $0.feature == .followUp }!
        let translation = PausedContentURLProtocol.requests.first { $0.feature == .translation }!
        answer.send(try Self.event(#"{"answer":"小林负责"#))
        translation.send(try Self.event(#"{"cues":[{"index":0,"text":"Xiaolin"#))
        try await waitUntil {
            store.insightGeneration(for: record.id, feature: .followUp)?.preview == "小林负责" &&
            store.insightGeneration(for: record.id, feature: .translation)?.preview == "Xiaolin"
        }
        answer.send(try Self.event(#"提交设计稿。"}"#, finishReason: "stop") + Self.done)
        translation.send(try Self.event(#" will submit the design on Friday."}]}"#, finishReason: "stop") + Self.done)
        try await waitUntil { !store.generatingInsights }
        XCTAssertEqual(store.selected?.contentInsights?.answers?.first?.question, "谁负责？")
        XCTAssertEqual(store.selected?.contentInsights?.answers?.first?.answer, "小林负责提交设计稿。")
        XCTAssertEqual(store.selected?.contentInsights?.translation?.segments.first?.text, "Xiaolin will submit the design on Friday.")
        XCTAssertEqual(store.selected?.contentInsights?.translation?.segments.first?.id, record.segments[0].id)
    }

    @MainActor
    func testTotalDeadlineStopsAnActiveStreamAndKeepsCompletedParallelResult() async throws {
        let (store, directory, session) = makeStore(timeout: 0.3)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let record = recording("原文")
        store.recordings = [record]; store.selectedID = record.id
        let started = Date()
        store.generateInsight(.overview); store.generateInsight(.tasks)
        try await waitUntil { PausedContentURLProtocol.requests.count == 2 }
        let overview = PausedContentURLProtocol.request(.overview, source: record.transcript)!
        overview.send(try Self.event(#"{"summary":"未完内容"#))
        PausedContentURLProtocol.request(.tasks, source: record.transcript)!.send(try Self.event(#"{"tasks":[]}"#, finishReason: "stop") + Self.done)
        try await waitUntil { store.insightGeneration(for: record.id, feature: .overview)?.preview == "未完内容" }
        // Keep the connection active; this must not extend the total deadline.
        for _ in 0..<8 {
            overview.send(Data(": keep-alive\n\n".utf8))
            try await Task.sleep(for: .milliseconds(40))
        }
        try await waitUntil { !store.generatingInsights }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(store.selected?.contentInsights?.errors?["overview"]?.contains("超时") == true)
        XCTAssertNil(store.selected?.contentInsights?.overview)
        XCTAssertEqual(store.selected?.contentInsights?.tasks, [])
    }

    private func configuration() -> ProcessingConfiguration {
        ProcessingConfiguration(insightsBaseURL: "https://stream.example/v1", insightsAPIKey: "test-key", summaryModel: "test-model")
    }

    @MainActor
    private func makeStore(timeout: TimeInterval = 180) -> (AppStore, URL, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PausedContentURLProtocol.self]
        let session = URLSession(configuration: config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (AppStore(engine: ProcessingEngine(session: session, contentRequestTimeout: timeout), directory: directory, initialConfiguration: configuration()), directory, session)
    }

    private func recording(_ text: String) -> Recording {
        Recording(title: text, duration: 1, sourceKind: .audio, segments: [.init(start: 0, duration: 1, text: text)])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProcessingFailure.message("Timed out waiting for concurrent streaming requests")
    }

    private static let done = Data("data: [DONE]\n\n".utf8)
    private static func event(_ content: String, finishReason: String? = nil) throws -> Data {
        var choice: [String: Any] = ["index": 0, "delta": ["content": content]]
        if let finishReason { choice["finish_reason"] = finishReason }
        return Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: ["choices": [choice]])) + Data("\r\n\r\n".utf8)
    }
}

private final class PausedContentURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stored: [PausedContentURLProtocol] = []
    private let delivery = DispatchQueue(label: "rustle.test.stream")
    private var stopped = false
    private(set) var feature: InsightFeature = .overview
    private(set) var source = ""
    static var requests: [PausedContentURLProtocol] { lock.lock(); defer { lock.unlock() }; return stored }
    static func reset() { lock.lock(); stored.removeAll(); lock.unlock() }
    static func request(_ feature: InsightFeature, source: String) -> PausedContentURLProtocol? {
        requests.last { $0.feature == feature && $0.source == source }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stream.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        delivery.async {
            do {
                let body = try JSONSerialization.jsonObject(with: Self.body(self.request)) as! [String: Any]
                XCTAssertEqual(body["stream"] as? Bool, true)
                let messages = body["messages"] as! [[String: String]]
                let prompt = messages[0]["content"]!
                self.source = messages[1]["content"]!
                if prompt.contains("只生成思维导图") { self.feature = .mindMap }
                else if prompt.contains("只提取明确约定的待办") { self.feature = .tasks }
                else if prompt.contains("回答question") { self.feature = .followUp }
                else if prompt.contains("将每条字幕翻译成") { self.feature = .translation }
                else { self.feature = .overview }
                let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                Self.lock.lock(); Self.stored.append(self); Self.lock.unlock()
            } catch { self.client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    func send(_ data: Data, complete: Bool = false) {
        delivery.async {
            guard !self.stopped else { return }
            self.client?.urlProtocol(self, didLoad: data)
            if complete { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { delivery.async { self.stopped = true } }
    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
