import XCTest
import Foundation
@testable import Rustle

final class ProcessingEngineTests: XCTestCase {
    private func configuration() -> ProcessingConfiguration {
        ProcessingConfiguration(provider: .dashScope, localeIdentifier: "zh-CN", apiKey: "unit-test-not-real", baseURL: "https://service.example/v1", transcriptionModel: DashScopeASR.defaultModel, insightsBaseURL: "https://service.example/v1", insightsAPIKey: "summary-unit-test-not-real", summaryModel: "gpt-4o-mini")
    }
    private func engine() -> ProcessingEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProcessingMockURLProtocol.self]
        return ProcessingEngine(session: URLSession(configuration: configuration))
    }
    override func tearDown() { ProcessingMockURLProtocol.handler = nil; ProcessingMockURLProtocol.responseHeaders = [:]; super.tearDown() }

    func testEndpointSecurityAndCompatibleLocalService() throws {
        var config = configuration()
        XCTAssertEqual(try ProcessingEngine.apiEndpoint(config, path: "chat/completions").absoluteString, "https://service.example/v1/chat/completions")
        config.baseURL = "http://127.0.0.1:9000/v1/"
        XCTAssertEqual(try ProcessingEngine.apiEndpoint(config, path: "chat/completions").absoluteString, "http://127.0.0.1:9000/v1/chat/completions")
        for url in ["http://service.example/v1", "file:///etc/passwd", "https://user:pass@service.example/v1", "https://service.example/v1?key=secret", "https://service.example/v1#fragment"] {
            config.baseURL = url
            XCTAssertThrowsError(try ProcessingEngine.apiEndpoint(config, path: "chat/completions"), url)
        }
        config = configuration(); config.apiKey = "secret\ninvalid"
        XCTAssertThrowsError(try ProcessingEngine.apiEndpoint(config, path: "chat/completions"))
    }

    func testInsightSchemaRejectsBadShapeAndDoesNotInventOwnersOrDates() throws {
        let data = Data(#"{"summary":"确定交付计划。","keyPoints":["优先完成设计"],"tasks":[{"title":"提交设计稿","owner":"李四","dueDate":"2026-10-30"},{"title":"确认方案","owner":null,"dueDate":null}]}"#.utf8)
        let result = try ProcessingEngine.parseInsights(data, source: "周五提交设计稿并确认方案。")
        XCTAssertTrue(result.isAIGenerated)
        XCTAssertEqual(result.tasks[0].owner, "待分配")
        XCTAssertEqual(result.tasks[0].dueDate, "未设截止日期")
        XCTAssertEqual(result.tasks[1].owner, "待分配")
        for value in ["not JSON", "{}", #"{"summary":"","keyPoints":[],"tasks":[]}"#, #"{"summary":"总结","keyPoints":"bad","tasks":[]}"#] {
            XCTAssertThrowsError(try ProcessingEngine.parseInsights(Data(value.utf8), source: "原文"))
        }
        let valid = Data(#"{"summary":"交付设计稿。","keyPoints":[],"tasks":[{"title":"提交设计稿","owner":"小林","dueDate":"周五"}]}"#.utf8)
        let assigned = try ProcessingEngine.parseInsights(valid, source: "小林负责在周五提交设计稿。")
        XCTAssertEqual(assigned.tasks[0].owner, "小林")
        XCTAssertEqual(assigned.tasks[0].dueDate, "周五")
    }

    func testUnicodeChunkingDoesNotDropAnyTranscript() {
        let text = String(repeating: "完整文字和表情🙂。", count: 5000)
        let chunks = ProcessingEngine.splitText(text, limit: 12000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 12000 })
        XCTAssertEqual(chunks.joined(), text)
    }

    func testMissingSummaryKeyReportsConfigurationErrorWithoutLocalFallback() async {
        ProcessingMockURLProtocol.handler = { _ in XCTFail("Must not send a request without summary credentials"); return (500, Data()) }
        var config = configuration()
        config.insightsAPIKey = ""
        do {
            _ = try await engine().generateInsights(transcript: "决定优先处理用户反馈。待办：整理问题清单。", configuration: config)
            XCTFail("Summary must require its own API key even when ASR has a key")
        } catch { XCTAssertTrue(error.localizedDescription.contains("内容整理 API Key")) }
    }

    func testSummaryUsesIndependentEndpointAndCredentials() async throws {
        ProcessingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "content.example")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer summary-unit-test-not-real")
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "custom-model")
            XCTAssertNil(body["thinking"])
            XCTAssertNil(body["reasoning_effort"])
            XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
            return (200, Self.chatResponse(summary: "真实 API 总结", task: nil))
        }
        var config = configuration()
        config.insightsBaseURL = "https://content.example/v1"
        config.summaryModel = "custom-model"
        let result = try await engine().generateInsights(transcript: "产品会议原文。", configuration: config)
        XCTAssertTrue(result.isAIGenerated)
        XCTAssertEqual(config.baseURL, "https://service.example/v1")
        XCTAssertEqual(config.apiKey, "unit-test-not-real")
    }

    func testAPIUnavailableThrowsWithoutGeneratingExtracts() async {
        ProcessingMockURLProtocol.handler = { _ in (503, Data()) }
        do {
            _ = try await engine().generateInsights(transcript: "待办：提交设计稿。", configuration: configuration())
            XCTFail("An API failure must remain a failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("暂时不可用")) }
    }

    func testRealAPIContractUsesJSONModeAndParsesResult() async throws {
        ProcessingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer summary-unit-test-not-real")
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
            let messages = body["messages"] as! [[String: String]]
            XCTAssertTrue(messages[0]["content"]!.contains("JSON"))
            XCTAssertEqual(messages[1]["content"], "小林周五提交设计稿。")
            return (200, Self.chatResponse(summary: "周五交付设计稿。", task: "提交设计稿"))
        }
        let result = try await engine().generateInsights(transcript: "小林周五提交设计稿。", configuration: configuration())
        XCTAssertTrue(result.isAIGenerated)
        XCTAssertEqual(result.tasks[0].title, "提交设计稿")
    }

    func testLongTranscriptProcessesAllChunksAndRetainsTasks() async throws {
        var sourceChunks: [String] = []
        ProcessingMockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            if messages[0]["content"]!.contains("当前资料是分段总结") { return (200, Self.chatResponse(summary: "全部材料的综合总结", task: nil)) }
            sourceChunks.append(messages[1]["content"]!)
            return (200, Self.chatResponse(summary: "当前分段的重要结论", task: "任务\(sourceChunks.count)"))
        }
        let text = String(repeating: "每段材料都包含需要保留的信息。", count: 2200)
        let result = try await engine().generateInsights(transcript: text, configuration: configuration())
        XCTAssertEqual(sourceChunks.joined(), text)
        XCTAssertEqual(result.tasks.count, sourceChunks.count)
        XCTAssertGreaterThan(sourceChunks.count, 1)
        XCTAssertEqual(result.summary, "全部材料的综合总结")
    }

    func testAPIErrorDoesNotExposeProviderBodyOrAPIKey() async {
        ProcessingMockURLProtocol.handler = { _ in (401, Data("secret unit-test-not-real backend detail".utf8)) }
        do { _ = try await engine().generateInsights(transcript: "原文", configuration: configuration()); XCTFail("Expected auth failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("API Key")); XCTAssertFalse(error.localizedDescription.contains("unit-test-not-real")); XCTAssertFalse(error.localizedDescription.contains("backend detail")) }
    }

    func testIncompleteSummaryIsRejected() async {
        ProcessingMockURLProtocol.handler = { _ in (200, Data(#"{"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}"#.utf8)) }
        do { _ = try await engine().generateInsights(transcript: "原文", configuration: configuration()); XCTFail("Expected incomplete output failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未完整生成")) }
    }

    func testLocalMediaIsCopiedIntoManagedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("录音.wav")
        let bytes = Self.waveFixture()
        try bytes.write(to: original)
        let directory = root.appendingPathComponent("managed")
        let copy = try await engine().prepareMedia(from: original, destinationDirectory: directory)
        XCTAssertNotEqual(copy.url, original)
        XCTAssertEqual(copy.title, "录音")
        XCTAssertTrue(copy.url.path.hasPrefix(directory.path + "/"))
        XCTAssertEqual(try Data(contentsOf: copy.url), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testNativeAudioExportAndDashScopeTranscriptionWithoutPaidRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("sample.wav")
        try Self.waveFixture().write(to: original)
        ProcessingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/services/aigc/multimodal-generation/generation")
            let body = ProcessingMockURLProtocol.body(request)
            XCTAssertGreaterThan(body.count, 100)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (200, Self.asrResponse("这是实际媒体流程的测试转写。"))
        }
        let result = try await engine().transcribe(url: original, configuration: configuration())
        XCTAssertEqual(result.segments[0].text, "这是实际媒体流程的测试转写。")
        XCTAssertGreaterThan(result.duration, 0.3)
        XCTAssertLessThan(result.duration, 1)
    }

    func testCancelledOperationStopsBeforeNetwork() async {
        ProcessingMockURLProtocol.handler = { _ in XCTFail("Cancelled operation must not send a request"); return (500, Data()) }
        let engine = engine(); let config = configuration()
        let task = Task {
            try Task.checkCancellation()
            return try await engine.generateInsights(transcript: "原文", configuration: config)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOverviewAndTasksHaveIndependentAPIContracts() async throws {
        var prompts: [String] = []
        ProcessingMockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let prompt = (body["messages"] as! [[String: String]])[0]["content"]!
            prompts.append(prompt)
            if prompt.contains("只生成概览") {
                return (200, Self.jsonChatResponse(["summary": "本周提交设计稿", "keyPoints": ["确认交付时间"]]))
            }
            return (200, Self.jsonChatResponse(["tasks": [["title": "提交设计稿", "owner": "小林", "dueDate": "周五"]]]))
        }
        let overview = try await engine().generateOverview(transcript: "小林周五提交设计稿", configuration: configuration())
        XCTAssertEqual(overview.summary, "本周提交设计稿")
        XCTAssertFalse(prompts[0].contains("\"tasks\""))
        let tasks = try await engine().generateActionItems(transcript: "小林周五提交设计稿", configuration: configuration())
        XCTAssertEqual(tasks[0].owner, "小林")
        XCTAssertEqual(tasks[0].dueDate, "周五")
        XCTAssertFalse(prompts[1].contains("\"summary\""))
    }

    func testMindMapValidatesNestedStructure() async throws {
        ProcessingMockURLProtocol.handler = { _ in (200, Self.jsonChatResponse(["title": "交付计划", "children": [["title": "设计", "children": []]]])) }
        let result = try await engine().generateMindMap(transcript: "讨论设计交付计划", configuration: configuration())
        XCTAssertEqual(result.children[0].title, "设计")
        ProcessingMockURLProtocol.handler = { _ in (200, Self.jsonChatResponse(["title": "", "children": []])) }
        do { _ = try await engine().generateMindMap(transcript: "原文", configuration: configuration()); XCTFail("Empty map title must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("结构")) }
    }

    func testMindMapAcceptsOmittedAndNullLeafChildrenAndRoundTrips() async throws {
        var requests = 0
        ProcessingMockURLProtocol.handler = { _ in
            requests += 1
            return (200, Self.jsonChatResponse(["title": " 交付计划\n", "children": [["title": "设计"], ["title": "验收", "children": NSNull()]]]))
        }
        let map = try await engine().generateMindMap(transcript: "讨论设计和验收", configuration: configuration())
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(map.title, "交付计划")
        XCTAssertEqual(map.children.map(\.children), [[], []])
        XCTAssertEqual(try JSONDecoder().decode(MindMapNode.self, from: JSONEncoder().encode(map)), map)
    }

    func testMindMapRepairsExcessiveDepthWithSourceAndValidationFeedback() async throws {
        let tooDeep = (1...5).reversed().reduce([String: Any]()) { child, level in
            ["title": "第\(level)层", "children": child.isEmpty ? [] : [child]]
        }
        var requests = 0
        ProcessingMockURLProtocol.handler = { request in
            requests += 1
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            XCTAssertTrue(messages[0]["content"]!.contains("根节点算第1层"))
            if requests == 1 { return (200, Self.jsonChatResponse(tooDeep)) }
            let repair = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
            XCTAssertEqual(repair["source"], "讨论设计和验收")
            XCTAssertTrue(repair["validationError"]!.contains("超过4层"))
            XCTAssertTrue(repair["previousResult"]!.contains("第5层"))
            return (200, Self.jsonChatResponse(["title": "交付计划", "children": [["title": "设计和验收"]]]))
        }
        let map = try await engine().generateMindMap(transcript: "讨论设计和验收", configuration: configuration())
        XCTAssertEqual(map.children[0].title, "设计和验收")
        XCTAssertEqual(requests, 2)
    }

    func testMindMapRepairIsBoundedAndExplainsStructuralFailures() async {
        let leaf: [String: Any] = ["title": "细节", "children": []]
        let branch: [String: Any] = ["title": "主题", "children": Array(repeating: leaf, count: 8)]
        let invalid: [([String: Any], String)] = [
            (["title": "根", "children": Array(repeating: leaf, count: 9)], "超过8个"),
            (["title": "根", "children": Array(repeating: branch, count: 8)], "超过60个"),
            (["title": " \n", "children": []], "标题为空"),
            (["title": "根", "children": "错误类型"], "节点数组"),
            (["mindMap": leaf], "根节点JSON")
        ]
        for (object, reason) in invalid {
            var requests = 0
            ProcessingMockURLProtocol.handler = { _ in requests += 1; return (200, Self.jsonChatResponse(object)) }
            do {
                _ = try await engine().generateMindMap(transcript: "原文", configuration: configuration())
                XCTFail("Invalid map must be rejected after one repair")
            } catch { XCTAssertTrue(error.localizedDescription.contains(reason)) }
            XCTAssertEqual(requests, 2)
        }
    }

    func testMindMapDoesNotRetryProviderFailures() async {
        for status in [401, 429, 503] {
            var requests = 0
            ProcessingMockURLProtocol.handler = { _ in requests += 1; return (status, Data()) }
            do { _ = try await engine().generateMindMap(transcript: "原文", configuration: configuration()); XCTFail("Expected provider failure") }
            catch { XCTAssertFalse(error.localizedDescription.contains("结构")) }
            XCTAssertEqual(requests, 1)
        }
    }

    func testMindMapProcessesEveryChunkAndMergesResults() async throws {
        let text = String(repeating: "完整文字🙂", count: 2100)
        var inputs: [String] = []
        ProcessingMockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            inputs.append(messages[1]["content"]!)
            return (200, Self.jsonChatResponse(["title": "主题\(inputs.count)", "children": []]))
        }
        let map = try await engine().generateMindMap(transcript: text, configuration: configuration())
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0], text)
        XCTAssertEqual(map.title, "主题1")
        inputs = []
        let longText = text + text
        let merged = try await engine().generateMindMap(transcript: longText, configuration: configuration())
        XCTAssertEqual(inputs.count, 3)
        XCTAssertEqual(inputs[0] + inputs[1], longText)
        XCTAssertTrue(inputs[2].contains("主题1"))
        XCTAssertTrue(inputs[2].contains("主题2"))
        XCTAssertEqual(merged.title, "主题3")
    }

    @MainActor
    func testMindMapTimeoutClearsGeneratingStateAndKeepsPreviousResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StalledContentURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let engine = ProcessingEngine(session: session, contentRequestTimeout: 0.15)
        let store = AppStore(engine: engine, directory: directory, initialConfiguration: configuration())
        let oldMap = MindMapNode(title: "已有导图", children: [MindMapNode(title: "已有分支")])
        let record = Recording(title: "超时测试", duration: 1, sourceKind: .audio,
                               segments: [.init(start: 0, duration: 1, text: "保留原文")],
                               contentInsights: ContentInsights(mindMap: oldMap))
        store.recordings = [record]; store.selectedID = record.id
        let start = Date()
        store.generateInsight(.mindMap)
        XCTAssertTrue(store.generatingInsights)
        XCTAssertNotNil(store.insightGeneration(for: record.id, feature: .mindMap)?.startedAt)
        try await waitUntil { !store.generatingInsights }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertNil(store.insightGeneration(for: record.id, feature: .mindMap))
        XCTAssertNil(store.insightGeneration(for: record.id, feature: .mindMap)?.startedAt)
        XCTAssertEqual(store.insightGeneration(for: record.id, feature: .mindMap)?.progress ?? "", "")
        XCTAssertEqual(store.selected?.contentInsights?.mindMap, oldMap)
        XCTAssertEqual(store.selected?.transcript, "保留原文")
        XCTAssertTrue(store.selected?.contentInsights?.errors?["mindMap"]?.contains("超时") == true)
        let reloaded = AppStore(directory: directory, initialConfiguration: configuration())
        XCTAssertEqual(reloaded.selected?.contentInsights?.mindMap, oldMap)
    }

    @MainActor
    func testCancellingStalledMindMapClearsGeneratingStateWithoutFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StalledContentURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let store = AppStore(engine: ProcessingEngine(session: session), directory: directory, initialConfiguration: configuration())
        let record = Recording(title: "取消测试", duration: 1, sourceKind: .audio, segments: [.init(start: 0, duration: 1, text: "保留原文")])
        store.recordings = [record]; store.selectedID = record.id
        store.generateInsight(.mindMap)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(store.generatingInsights)
        store.cancelInsightGeneration()
        try await waitUntil { !store.generatingInsights }
        XCTAssertNil(store.insightGeneration(for: record.id, feature: .mindMap)?.startedAt)
        XCTAssertEqual(store.insightGeneration(for: record.id, feature: .mindMap)?.progress ?? "", "")
        XCTAssertNil(store.selected?.contentInsights?.errors?["mindMap"])
        XCTAssertEqual(store.selected?.transcript, "保留原文")
    }

    func testQuestionIncludesTranscriptAndRecentConversation() async throws {
        let history = (0..<8).map { FollowUpAnswer(question: "历史问题\($0)", answer: "历史回答\($0)") }
        ProcessingMockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
            XCTAssertEqual(input["source"], "小林负责设计")
            XCTAssertEqual(input["question"], "谁负责？")
            XCTAssertFalse(input["history"]!.contains("历史问题0"))
            XCTAssertTrue(input["history"]!.contains("历史问题7"))
            return (200, Self.jsonChatResponse(["answer": "小林。依据：小林负责设计。"] ))
        }
        let result = try await engine().answerQuestion("谁负责？", transcript: "小林负责设计", history: history, configuration: configuration())
        XCTAssertEqual(result.question, "谁负责？")
        XCTAssertTrue(result.answer.contains("小林"))
    }

    func testSubtitleTranslationPreservesIdentityTimingAndOrderAcrossBatches() async throws {
        var requests = 0
        let segments = (0..<45).map { TranscriptSegment(start: Double($0) * 1.75, duration: 1.25, text: "字幕\($0)") }
        ProcessingMockURLProtocol.handler = { request in
            requests += 1
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            XCTAssertTrue(messages[0]["content"]!.contains("英语"))
            let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [[String: Any]]
            // The service may return a different order; indices must still map to the original cues.
            let cues = input.reversed().map { ["index": $0["index"]!, "text": "Caption \($0["index"]!)"] }
            return (200, Self.jsonChatResponse(["cues": cues]))
        }
        let result = try await engine().translateSubtitles(segments: segments, language: .english, configuration: configuration())
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(result.segments.map(\.id), segments.map(\.id))
        XCTAssertEqual(result.segments.map(\.start), segments.map(\.start))
        XCTAssertEqual(result.segments.map(\.duration), segments.map(\.duration))
        XCTAssertEqual(result.segments[44].text, "Caption 44")
        var record = Recording(title: "译文", duration: 80, sourceKind: .audio, segments: result.segments)
        let srt = TranscriptExporter.export(record, format: .srt)
        XCTAssertTrue(srt.contains("00:00:01,750 --> 00:00:03,000\nCaption 1"))
        record.segments = segments
        XCTAssertEqual(record.segments[44].text, "字幕44")
    }

    func testSubtitleTranslationRejectsMissingAndDuplicateIndices() async {
        let segments = [TranscriptSegment(start: 0, duration: 1, text: "你好"), TranscriptSegment(start: 1, duration: 1, text: "再见")]
        for cues in [ [["index": 0, "text": "Hello"]], [["index": 0, "text": "Hello"], ["index": 0, "text": "Goodbye"]] ] {
            var requests = 0
            ProcessingMockURLProtocol.handler = { _ in requests += 1; return (200, Self.jsonChatResponse(["cues": cues])) }
            do { _ = try await engine().translateSubtitles(segments: segments, language: .english, configuration: configuration()); XCTFail("Invalid cue indices must be rejected") }
            catch { XCTAssertTrue(error.localizedDescription.contains("编号")) }
            XCTAssertEqual(requests, 2)
        }
    }

    func testSubtitleTranslationAcceptsFencesAndStringIndicesWithoutChangingEmptyCues() async throws {
        let segments = [TranscriptSegment(start: 0, duration: 1, text: "你好"), TranscriptSegment(start: 1, duration: 1, text: " \n"), TranscriptSegment(start: 2, duration: 1, text: "再见", speaker: "小林")]
        ProcessingMockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            let cues = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [[String: Any]]
            XCTAssertEqual(cues.compactMap { $0["index"] as? Int }, [0, 2])
            return (200, Self.rawChatResponse("```json\n{\"cues\":[{\"index\":\"2\",\"text\":\" Goodbye \"},{\"index\":\"0\",\"text\":\"Hello\"}]}\n```"))
        }
        let result = try await engine().translateSubtitles(segments: segments, language: .english, configuration: configuration())
        var expected = segments
        expected[0].text = "Hello"; expected[2].text = "Goodbye"
        XCTAssertEqual(result.segments, expected)
    }

    func testSubtitleTranslationRepairsMalformedJSONAndWrongIndicesOnce() async throws {
        let segments = [TranscriptSegment(start: 3, duration: 2, text: "你好")]
        for invalid in ["not JSON", #"{"cues":[{"index":1,"text":"Hello"}]}"#, #"{"cues":[{"index":0,"text":"  "}]}"#] {
            var requests = 0
            ProcessingMockURLProtocol.handler = { request in
                requests += 1
                if requests == 1 { return (200, Self.rawChatResponse(invalid)) }
                let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
                let messages = body["messages"] as! [[String: String]]
                let repair = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
                XCTAssertEqual(repair["previousResult"], invalid)
                XCTAssertTrue(repair["source"]!.contains("你好"))
                XCTAssertTrue(messages[0]["content"]!.contains("英语"))
                return (200, Self.jsonChatResponse(["cues": [["index": 0, "text": "Hello"]]]))
            }
            let result = try await engine().translateSubtitles(segments: segments, language: .english, configuration: configuration())
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(result.segments[0].text, "Hello")
            XCTAssertEqual(result.segments[0].id, segments[0].id)
        }
    }

    func testSubtitleTranslationSplitsTruncatedBatchesAndKeepsGlobalIndices() async throws {
        let segments = (0..<4).map { TranscriptSegment(start: Double($0), duration: 1, text: "字幕\($0)") }
        var batches: [[Int]] = []
        ProcessingMockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            let cues = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [[String: Any]]
            let indices = cues.compactMap { $0["index"] as? Int }
            batches.append(indices)
            if cues.count > 2 { return (200, Self.rawChatResponse("{\"cues\":[", finishReason: "length")) }
            let example = "\"index\":\(indices[0])"
            XCTAssertTrue(messages[0]["content"]!.contains(example))
            return (200, Self.jsonChatResponse(["cues": indices.reversed().map { ["index": $0, "text": "Caption \($0)"] }]))
        }
        let result = try await engine().translateSubtitles(segments: segments, language: .english, configuration: configuration())
        XCTAssertEqual(batches, [[0, 1, 2, 3], [0, 1], [2, 3]])
        XCTAssertEqual(result.segments.map(\.text), ["Caption 0", "Caption 1", "Caption 2", "Caption 3"])
        XCTAssertEqual(result.segments.map(\.id), segments.map(\.id))
    }

    func testSubtitleTranslationRetriesRateLimitsAndReportsProgress() async throws {
        var requests = 0
        ProcessingMockURLProtocol.responseHeaders = ["Retry-After": "0"]
        ProcessingMockURLProtocol.handler = { _ in
            requests += 1
            if requests < 3 { return (429, Data()) }
            return (200, Self.jsonChatResponse(["cues": [["index": 0, "text": "Hello"]]]))
        }
        let progress = SubtitleProgressLog()
        let result = try await engine().translateSubtitles(segments: [TranscriptSegment(start: 0, duration: 1, text: "你好")], language: .english, configuration: configuration(), progress: { progress.append($0) })
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(result.segments[0].text, "Hello")
        XCTAssertEqual(progress.values.filter { $0.contains("服务暂时限流") }.count, 2)
        XCTAssertTrue(progress.values.last!.contains("已翻译 1/1"))
    }

    func testSubtitleTranslationBoundsRetriesAndDoesNotRetryQuotaOrAuthenticationFailures() async {
        let segments = [TranscriptSegment(start: 0, duration: 1, text: "你好")]
        let quota = Data(#"{"error":{"code":"insufficient_quota","message":"secret provider detail"}}"#.utf8)
        for (status, data, expectedRequests) in [(429, Data(), 3), (429, quota, 1), (401, Data(), 1), (503, Data(), 1)] {
            var requests = 0
            ProcessingMockURLProtocol.responseHeaders = ["Retry-After": "0"]
            ProcessingMockURLProtocol.handler = { _ in requests += 1; return (status, data) }
            do { _ = try await engine().translateSubtitles(segments: segments, language: .english, configuration: configuration()); XCTFail("Expected service failure") }
            catch { XCTAssertFalse(error.localizedDescription.contains("secret provider detail")) }
            XCTAssertEqual(requests, expectedRequests)
        }
        var requests = 0
        ProcessingMockURLProtocol.responseHeaders = ["Retry-After": "120"]
        ProcessingMockURLProtocol.handler = { _ in requests += 1; return (429, Data()) }
        do { _ = try await engine().translateSubtitles(segments: segments, language: .english, configuration: configuration()); XCTFail("Long server backoff should be surfaced") }
        catch { XCTAssertTrue(error.localizedDescription.contains("请求过于频繁")) }
        XCTAssertEqual(requests, 1)
    }

    func testSubtitleTranslationCancellationInterruptsRateLimitWait() async throws {
        let progress = SubtitleProgressLog()
        ProcessingMockURLProtocol.responseHeaders = ["Retry-After": "30"]
        ProcessingMockURLProtocol.handler = { _ in (429, Data()) }
        let engine = engine(), config = configuration()
        let task = Task {
            try await engine.translateSubtitles(segments: [TranscriptSegment(start: 0, duration: 1, text: "你好")], language: .english, configuration: config, progress: { progress.append($0) })
        }
        for _ in 0..<100 where !progress.values.contains(where: { $0.contains("服务暂时限流") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(progress.values.contains { $0.contains("服务暂时限流") })
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled wait must not continue translating") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testSubtitleTranslationFailureKeepsPreviousResultAndSuccessfulRetryPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let segments = (0..<41).map { TranscriptSegment(start: Double($0), duration: 1, text: "字幕\($0)") }
        let previous = SubtitleTranslation(language: .english, segments: segments.map {
            var cue = $0; cue.text = "Previous \(cue.text)"; return cue
        })
        let record = Recording(title: "字幕重试", duration: 41, sourceKind: .audio, segments: segments, contentInsights: ContentInsights(translation: previous))
        let store = AppStore(engine: engine(), directory: directory, initialConfiguration: configuration())
        store.recordings = [record]; store.selectedID = record.id
        var requests = 0
        var failSecondBatch = true
        ProcessingMockURLProtocol.handler = { request in
            requests += 1
            if failSecondBatch && requests == 2 { return (401, Data()) }
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            let cues = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [[String: Any]]
            return (200, Self.jsonChatResponse(["cues": cues.map { ["index": $0["index"]!, "text": "日本語\($0["index"]!)"] }]))
        }
        store.generateInsight(.translation, language: .japanese)
        try await waitUntil { !store.generatingInsights }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(store.selected?.segments, segments)
        XCTAssertEqual(store.selected?.contentInsights?.translation, previous)
        XCTAssertTrue(store.selected?.contentInsights?.errors?["translation"]?.contains("API Key") == true)
        XCTAssertNil(store.insightGeneration(for: record.id, feature: .translation)?.startedAt)
        XCTAssertEqual(store.insightGeneration(for: record.id, feature: .translation)?.progress ?? "", "")
        failSecondBatch = false
        store.generateInsight(.translation, language: .japanese)
        try await waitUntil { !store.generatingInsights }
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(store.selected?.contentInsights?.translation?.language, .japanese)
        XCTAssertEqual(store.selected?.contentInsights?.translation?.segments.last?.text, "日本語40")
        XCTAssertNil(store.selected?.contentInsights?.errors?["translation"])
        let reloaded = AppStore(directory: directory, initialConfiguration: configuration())
        XCTAssertEqual(reloaded.selected?.segments, segments)
        XCTAssertEqual(reloaded.selected?.contentInsights?.translation, store.selected?.contentInsights?.translation)
    }

    @MainActor
    func testImportAutomaticallyGeneratesOnlyOverviewAndMindMapThenTasksOnClick() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("auto-insights.wav")
        try Self.waveFixture().write(to: media)
        let prompts = SubtitleProgressLog()
        ProcessingMockURLProtocol.handler = { request in
            if request.url?.path == "/v1/services/aigc/multimodal-generation/generation" {
                return (200, Self.asrResponse("小林周五提交设计稿"))
            }
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let prompt = (body["messages"] as! [[String: String]])[0]["content"]!
            prompts.append(prompt)
            if prompt.contains("只生成概览") { return (200, Self.jsonChatResponse(["summary": "确认设计交付", "keyPoints": []])) }
            if prompt.contains("只生成思维导图") { return (200, Self.jsonChatResponse(["title": "设计交付", "children": []])) }
            return (200, Self.jsonChatResponse(["tasks": []]))
        }
        let store = AppStore(engine: engine(), directory: directory.appendingPathComponent("library"), initialConfiguration: configuration())
        store.importMedia([media])
        try await waitUntil { store.selected?.title == "auto-insights" && store.processingID == nil && !store.generatingInsights }
        let record = store.selected!
        XCTAssertEqual(record.status, .ready)
        XCTAssertTrue(record.hasInsight(.overview))
        XCTAssertTrue(record.hasInsight(.mindMap))
        XCTAssertFalse(record.hasInsight(.tasks))
        XCTAssertFalse(record.hasInsight(.followUp))
        XCTAssertFalse(record.hasInsight(.translation))
        XCTAssertEqual(prompts.values.count, 2)
        store.generateInsight(.tasks)
        try await waitUntil { !store.generatingInsights }
        XCTAssertEqual(prompts.values.count, 3)
        XCTAssertEqual(store.selected?.actionItems, [])
        XCTAssertTrue(store.selected!.hasInsight(.tasks))
        let reloaded = AppStore(engine: engine(), directory: directory.appendingPathComponent("library"), initialConfiguration: configuration())
        XCTAssertTrue(reloaded.selected!.hasInsight(.overview))
        XCTAssertTrue(reloaded.selected!.hasInsight(.mindMap))
        XCTAssertTrue(reloaded.selected!.hasInsight(.tasks))
        XCTAssertEqual(prompts.values.count, 3)
    }

    @MainActor
    func testAutomaticOverviewFailureStillGeneratesMindMapAndKeepsTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("failed-overview.wav")
        try Self.waveFixture().write(to: media)
        ProcessingMockURLProtocol.handler = { request in
            if request.url?.path == "/v1/services/aigc/multimodal-generation/generation" { return (200, Self.asrResponse("保留转写文字")) }
            let body = try JSONSerialization.jsonObject(with: ProcessingMockURLProtocol.body(request)) as! [String: Any]
            let prompt = (body["messages"] as! [[String: String]])[0]["content"]!
            if prompt.contains("只生成概览") { return (503, Data()) }
            return (200, Self.jsonChatResponse(["title": "文稿主题", "children": []]))
        }
        let store = AppStore(engine: engine(), directory: directory.appendingPathComponent("library"), initialConfiguration: configuration())
        store.importMedia([media])
        try await waitUntil { store.selected?.title == "failed-overview" && store.processingID == nil && !store.generatingInsights }
        XCTAssertEqual(store.selected?.status, .ready)
        XCTAssertEqual(store.selected?.transcript, "保留转写文字")
        XCTAssertFalse(store.selected!.hasInsight(.overview))
        XCTAssertTrue(store.selected!.hasInsight(.mindMap))
        XCTAssertNotNil(store.selected?.contentInsights?.errors?[InsightFeature.overview.rawValue])
        XCTAssertNil(store.selected?.actionItems)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProcessingFailure.message("Timed out waiting for content insights")
    }

    private static func asrResponse(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["output": ["sentence": [
            "sentence_id": 1, "sentence_end": true, "begin_time": 0, "end_time": 300, "text": text
        ]]])
    }

    private static func jsonChatResponse(_ object: [String: Any]) -> Data {
        let content = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        return rawChatResponse(content)
    }

    private static func rawChatResponse(_ content: String, finishReason: String = "stop") -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finishReason, "message": ["content": content]]]])
    }

    private static func chatResponse(summary: String, task: String?) -> Data {
        let tasks: [[String: Any]] = task.map { [["title": $0, "owner": NSNull(), "dueDate": NSNull()]] } ?? []
        let insights: [String: Any] = ["summary": summary, "keyPoints": ["保留原文的重要信息"], "tasks": tasks]
        let content = String(data: try! JSONSerialization.data(withJSONObject: insights), encoding: .utf8)!
        return try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
    }
    private static func waveFixture() -> Data {
        var data = Data()
        func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func long(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        let samples = 6400
        data.append(Data("RIFF".utf8)); long(UInt32(36 + samples * 2)); data.append(Data("WAVEfmt ".utf8)); long(16)
        word(1); word(1); long(16000); long(32000); word(2); word(16); data.append(Data("data".utf8)); long(UInt32(samples * 2))
        for index in 0..<samples { let sample = Int16(sin(Double(index) * 2 * .pi * 440 / 16000) * 1200); word(UInt16(bitPattern: sample)) }
        return data
    }
}

private final class ProcessingMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var responseHeaders: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { ["service.example", "content.example"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            let headers = Self.responseHeaders.merging(["Content-Type": "application/json"]) { _, new in new }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
}

private final class SubtitleProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

// Responds with headers and partial bytes but never finishes the response.
// This exercises the total deadline independently of URLSession's idle timeout.
private final class StalledContentURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "service.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{".utf8))
    }
    override func stopLoading() {}
}
