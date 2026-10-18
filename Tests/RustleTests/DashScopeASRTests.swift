import XCTest
import Foundation
@testable import Rustle

final class DashScopeASRTests: XCTestCase {
    private func configuration() -> ProcessingConfiguration {
        var config = ProcessingConfiguration()
        config.provider = .dashScope
        config.baseURL = "https://asr.example/api/v1"
        config.apiKey = "asr-unit-test-not-real"
        config.transcriptionModel = DashScopeASR.defaultModel
        return config
    }

    override func tearDown() { DashScopeMockURLProtocol.handler = nil; super.tearDown() }

    func testEndpointAcceptsNativeAndCompatibleBasesButRejectsUnsafeURLs() throws {
        var config = configuration()
        for base in ["https://dashscope.aliyuncs.com", "https://dashscope.aliyuncs.com/api/v1/", "https://dashscope.aliyuncs.com/compatible-mode/v1"] {
            config.baseURL = base
            XCTAssertEqual(try DashScopeASR.endpoint(config).absoluteString, "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        }
        for base in ["http://asr.example/api/v1", "https://user:pass@asr.example/api/v1", "https://asr.example/api/v1?token=secret"] {
            config.baseURL = base
            XCTAssertThrowsError(try DashScopeASR.endpoint(config))
        }
    }

    func testNativeRequestUsesBase64WAVAndIndependentASRCredential() throws {
        var config = configuration()
        config.insightsAPIKey = "different-content-key"
        let audio = Data([82, 73, 70, 70, 0, 1, 2, 3])
        let request = try DashScopeASR.request(audio: audio, configuration: config)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer asr-unit-test-not-real")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-SSE"), "enable")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, DashScopeASR.defaultModel)
        XCTAssertNil(body["response_format"])
        let input = body["input"] as! [String: Any]
        let message = (input["messages"] as! [[String: Any]])[0]
        let content = (message["content"] as! [[String: Any]])[0]
        XCTAssertEqual((content["input_audio"] as! [String: String])["data"], "data:audio/wav;base64," + audio.base64EncodedString())
        let parameters = body["parameters"] as! [String: Any]
        XCTAssertEqual(parameters["language_hints"] as? [String], ["zh"])
        XCTAssertEqual(parameters["sample_rate"] as? String, "16000")
        config.localeIdentifier = "auto"
        let auto = try JSONSerialization.jsonObject(with: DashScopeASR.request(audio: audio, configuration: config).httpBody!) as! [String: Any]
        XCTAssertNil((auto["parameters"] as! [String: Any])["language_hints"])
    }

    func testRequestRejectsMissingCredentialOversizeAndInvalidModel() {
        var config = configuration(); config.apiKey = ""
        XCTAssertThrowsError(try DashScopeASR.request(audio: Data([1]), configuration: config))
        config = configuration(); config.transcriptionModel = "bad\nmodel"
        XCTAssertThrowsError(try DashScopeASR.request(audio: Data([1]), configuration: config))
        config = configuration()
        XCTAssertThrowsError(try DashScopeASR.request(audio: Data(), configuration: config))
        XCTAssertThrowsError(try DashScopeASR.request(audio: Data(count: 7_500_001), configuration: config))
    }

    func testFinalSSESentencesAreOrderedDeduplicatedAndOffsetInSeconds() throws {
        let partial = Self.event(id: 1, begin: 120, end: nil, text: "中间", final: false)
        let first = Self.event(id: 1, begin: 120, end: 900, text: "完整原文。")
        let second = Self.event(id: 2, begin: 1500, end: 2300, text: "第二句。")
        let data = Data((": heartbeat\r\n\r\n" + partial + second + first + first + "data: [DONE]\r\n\r\n").utf8)
        let result = try DashScopeASR.parse(data, offset: 180, duration: 3, locale: "zh-CN")
        XCTAssertEqual(result.segments.map(\.text), ["完整原文。", "第二句。"])
        XCTAssertEqual(result.segments[0].start, 180.12, accuracy: 0.0001)
        XCTAssertEqual(result.segments[0].duration, 0.78, accuracy: 0.0001)
        XCTAssertEqual(result.segments[1].start, 181.5, accuracy: 0.0001)
    }

    func testWordTimestampsSplitSubtitlesWithoutLosingPunctuationOrPauses() throws {
        let object: [String: Any] = ["output": ["text": "你好。下周完成！", "sentence": ["sentence_id": 1, "sentence_end": true, "begin_time": 100, "end_time": 2000,
            "text": "你好。下周完成！", "words": [
                ["text": "你好", "punctuation": "。", "begin_time": 100, "end_time": 600],
                ["text": "下周", "begin_time": 900, "end_time": 1300],
                ["text": "完成", "punctuation": "！", "begin_time": 1300, "end_time": 2000]
            ]]]]
        let result = try DashScopeASR.parse(JSONSerialization.data(withJSONObject: object), offset: 180, duration: 3, locale: "zh-CN")
        XCTAssertEqual(result.segments.map(\.text), ["你好。", "下周完成！"])
        XCTAssertEqual(result.segments[1].start, 180.9, accuracy: 0.0001)
        XCTAssertEqual(result.segments[1].duration, 1.1, accuracy: 0.0001)
    }

    func testIncompleteWordsDoNotDropSentenceText() throws {
        let object: [String: Any] = ["output": ["sentence": ["sentence_id": 1, "sentence_end": true, "begin_time": 100, "end_time": 2000,
            "text": "完整的原文。", "words": [["text": "部分", "begin_time": 100, "end_time": 200]]]]]
        let result = try DashScopeASR.parse(JSONSerialization.data(withJSONObject: object), offset: 0, duration: 3, locale: "zh-CN")
        XCTAssertEqual(result.segments.map(\.text), ["完整的原文。"])
    }

    func testGrowingFinalSnapshotsWithDifferentIDsDoNotRepeatEarlierSpeech() throws {
        let words: [[String: Any]] = [
            ["text": "开头", "punctuation": "。", "begin_time": 600, "end_time": 2000],
            ["text": "中间", "punctuation": "。", "begin_time": 12000, "end_time": 14000],
            ["text": "结尾", "punctuation": "。", "begin_time": 49000, "end_time": 51000]
        ]
        func snapshot(_ count: Int) throws -> String {
            let prefix = Array(words.prefix(count))
            let sentence: [String: Any] = ["sentence_id": count, "sentence_end": true,
                "begin_time": 600, "end_time": prefix.last!["end_time"]!,
                "text": prefix.map { ($0["text"] as! String) + "。" }.joined(), "words": prefix]
            let data = try JSONSerialization.data(withJSONObject: ["output": ["sentence": sentence]])
            return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
        }
        // Out-of-order retries must not replace the longest final snapshot.
        let stream = try snapshot(1) + snapshot(3) + snapshot(2) + snapshot(3)
        let result = try DashScopeASR.parse(Data(stream.utf8), offset: 180, duration: 60, locale: "zh-CN")
        XCTAssertEqual(result.segments.map(\.text), ["开头。", "中间。", "结尾。"])
        XCTAssertEqual(result.segments.map(\.start), [180.6, 192, 229])
        XCTAssertEqual(result.segments.map(\.duration), [1.4, 2, 2])
    }

    func testCumulativeSentencesWithoutWordsRetainLongestTextAndRealRepetition() throws {
        let stream = Self.event(id: 1, begin: 600, end: 2000, text: "你好。")
            + Self.event(id: 2, begin: 600, end: 14000, text: "你好。继续讨论。")
            + Self.event(id: 3, begin: 49000, end: 51000, text: "你好。")
        let result = try DashScopeASR.parse(Data(stream.utf8), offset: 0, duration: 60, locale: "zh-CN")
        XCTAssertEqual(result.segments.map(\.text), ["你好。继续讨论。", "你好。"])
        XCTAssertEqual(result.segments.map(\.start), [0.6, 49])
    }

    func testWordBasedCuesAreOrderedEvenWhenSentenceTimeRangesOverlap() throws {
        let object: [String: Any] = ["output": ["sentences": [
            ["sentence_id": 1, "sentence_end": true, "begin_time": 0, "end_time": 51000,
             "text": "后文。", "words": [["text": "后文。", "begin_time": 49000, "end_time": 51000]]],
            ["sentence_id": 2, "sentence_end": true, "begin_time": 0, "end_time": 2000,
             "text": "开头。", "words": [["text": "开头。", "begin_time": 600, "end_time": 2000]]]
        ]]]
        let result = try DashScopeASR.parse(JSONSerialization.data(withJSONObject: object), offset: 0, duration: 60, locale: "zh-CN")
        XCTAssertEqual(result.segments.map(\.start), [0.6, 49])
        XCTAssertEqual(result.segments.map(\.text), ["开头。", "后文。"])
    }

    func testIncompleteEventsProviderErrorsAndInvalidTimesAreRejected() {
        let inputs = [
            Self.event(id: 1, begin: 0, end: nil, text: "未完成", final: false),
            Self.event(id: 1, begin: -100, end: 200, text: "无效时间"),
            Self.event(id: 1, begin: 200, end: 100, text: "倒序时间"),
            Self.event(id: 1, begin: 0, end: 8000, text: "超出音频"),
            #"{"output":{"text":"有文字但缺少完整时间戳"}}"#,
            #"data: {"code":"InvalidApiKey","message":"secret-provider-body"}"#,
            "not an ASR response"
        ]
        for input in inputs {
            do { _ = try DashScopeASR.parse(Data(input.utf8), offset: 0, duration: 3, locale: "zh-CN"); XCTFail("Invalid result must fail") }
            catch { XCTAssertFalse(error.localizedDescription.contains("secret-provider-body")) }
        }
    }

    func testSilentResultIsEmptyAndTraditionalChineseIsNormalized() throws {
        let silent = try DashScopeASR.parse(Data(#"{"output":{"text":""}}"#.utf8), offset: 0, duration: 1, locale: "auto")
        XCTAssertEqual(silent.segments.count, 0)
        let chinese = try DashScopeASR.parse(Data(Self.event(id: 1, begin: 0, end: 500, text: "會議設計").utf8), offset: 0, duration: 1, locale: "zh-CN")
        XCTAssertEqual(chinese.segments[0].text, "会议设计")
    }

    func testLongAudioUsesBoundedWAVChunksAndPreservesGlobalTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("long.wav")
        try Self.wave(seconds: 181).write(to: input)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [DashScopeMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        var requests = 0
        DashScopeMockURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/api/v1/services/aigc/multimodal-generation/generation")
            let body = DashScopeMockURLProtocol.body(request)
            XCTAssertLessThan(body.count, 10_000_000)
            let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let input = payload["input"] as! [String: Any]
            let content = ((input["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]])[0]
            let uri = (content["input_audio"] as! [String: String])["data"]!
            let audio = Data(base64Encoded: String(uri.dropFirst("data:audio/wav;base64,".count)))!
            XCTAssertEqual(String(decoding: audio.prefix(4), as: UTF8.self), "RIFF")
            return Data(Self.event(id: 1, begin: 100, end: 800, text: "分段\(requests)").utf8)
        }
        let result = try await ProcessingEngine(session: session).transcribe(url: input, configuration: configuration())
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(result.segments.map(\.text), ["分段1", "分段2"])
        XCTAssertEqual(result.segments[1].start, 180.1, accuracy: 0.0001)
        XCTAssertEqual(result.duration, 181, accuracy: 0.001)
        let progress = ProcessingProgress.transcription(offset: 180, chunkDuration: 1, duration: 181, fraction: nil, local: false, chunkInterval: 180)
        XCTAssertTrue(progress.detail.contains("第 2/2 段"))
    }

    private static func event(id: Int, begin: Double, end: Double?, text: String, final: Bool = true) -> String {
        var sentence: [String: Any] = ["sentence_id": id, "sentence_end": final, "begin_time": begin, "text": text]
        if let end { sentence["end_time"] = end }
        let data = try! JSONSerialization.data(withJSONObject: ["output": ["sentence": sentence]])
        return "id: \(id)\r\nevent: result\r\ndata: " + String(decoding: data, as: UTF8.self) + "\r\n\r\n"
    }

    private static func wave(seconds: Int) -> Data {
        let byteCount = seconds * 16000 * 2
        var data = Data()
        func word(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func long(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); long(UInt32(36 + byteCount)); data.append(Data("WAVEfmt ".utf8)); long(16)
        word(1); word(1); long(16000); long(32000); word(2); word(16); data.append(Data("data".utf8)); long(UInt32(byteCount))
        data.append(Data(count: byteCount))
        return data
    }
}

private final class DashScopeMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "asr.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
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
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
