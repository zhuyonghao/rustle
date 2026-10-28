import AVFoundation
import Foundation
import XCTest
@testable import Rustle

final class LiveRecordingTests: XCTestCase {
    func testWriterClosesChunksAndFlushesTailWithoutLosingSamples() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let (stream, continuation) = AsyncThrowingStream<LiveAudioChunk, Error>.makeStream()
        let writer = try LiveAudioWriter(directory: directory, format: format, interval: 0.5, continuation: continuation, progress: { _ in })
        writer.append(buffer(seconds: 0.5, format: format))
        writer.append(buffer(seconds: 0.2, format: format))
        XCTAssertEqual(writer.finish(), 0.7, accuracy: 0.0001)
        XCTAssertEqual(writer.finish(), 0.7, accuracy: 0.0001)
        writer.append(buffer(seconds: 0.5, format: format))
        var chunks: [LiveAudioChunk] = []
        for try await chunk in stream {
            let file = try AVAudioFile(forReading: chunk.url)
            XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, chunk.duration, accuracy: 0.0001)
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertEqual(chunks[0].duration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(chunks[1].start, 0.5, accuracy: 0.0001)
        XCTAssertEqual(chunks[1].duration, 0.2, accuracy: 0.0001)
        let recording = try AVAudioFile(forReading: directory.appendingPathComponent("microphone.caf"))
        XCTAssertEqual(recording.length, 11200)
        let wave = directory.appendingPathComponent("full.wav")
        try await LocalWhisperService.exportWAV(from: directory.appendingPathComponent("microphone.caf"), start: 0, duration: 0.7, destination: wave)
        XCTAssertGreaterThan(try Data(contentsOf: wave).count, 20000)
    }

    func testChunkOffsetsClipSegmentsToTheirActualAudioRange() {
        let chunk = LiveAudioChunk(url: URL(fileURLWithPath: "/unused.caf"), start: 15.2, duration: 0.8)
        let input = [TranscriptSegment(start: 0.1, duration: 5, text: "尾段"),
                     TranscriptSegment(start: 0.9, duration: 1, text: "越界"),
                     TranscriptSegment(start: .nan, duration: 1, text: "无效"),
                     TranscriptSegment(start: 0, duration: 1, text: " ")]
        let output = chunk.offsetting(input)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].start, 15.3, accuracy: 0.0001)
        XCTAssertEqual(output[0].duration, 0.7, accuracy: 0.0001)
        XCTAssertEqual(output[0].id, input[0].id)
    }

    @MainActor
    func testPermissionDenialDoesNotCreateRecordOrMedia() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = TestLiveRecorder(); recorder.authorized = false
        let store = makeStore(directory: directory, recorder: recorder)
        let before = store.recordings
        store.startLiveRecording()
        try await waitUntil { store.liveSession == nil }
        XCTAssertEqual(store.recordings, before)
        XCTAssertTrue(store.alertMessage?.contains("麦克风权限") == true)
        XCTAssertFalse(recorder.started)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Media").path))
    }

    @MainActor
    func testLiveResultsArriveBeforeStopAndFinalTailKeepsAudioAndTitle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        LiveASRProtocol.reset()
        let recorder = TestLiveRecorder()
        let store = makeStore(directory: directory, recorder: recorder)
        store.startLiveRecording()
        try await waitUntil { store.liveSession?.phase == .recording }
        let id = try XCTUnwrap(store.liveSession?.id)
        XCTAssertNotNil(store.storageChangeUnavailableReason)
        recorder.append(seconds: 0.5)
        try await waitUntil { store.recordings.first { $0.id == id }?.segments.count == 1 }
        XCTAssertEqual(store.selected?.status, .processing)
        store.renameSelected("实时录音标题")
        let another = store.recordings.first { $0.id != id }!
        store.selectedID = another.id
        recorder.append(seconds: 0.2)
        store.stopLiveRecording()
        XCTAssertEqual(store.liveSession?.phase, .finishing)
        try await waitUntil { store.liveSession == nil }
        let record = try XCTUnwrap(store.recordings.first { $0.id == id })
        XCTAssertEqual(record.status, .ready)
        XCTAssertEqual(record.segments.count, 2)
        XCTAssertEqual(record.segments[0].start, 0)
        XCTAssertEqual(record.segments[1].start, 0.5, accuracy: 0.0001)
        XCTAssertEqual(record.duration, 0.7, accuracy: 0.0001)
        XCTAssertEqual(record.title, "实时录音标题")
        XCTAssertEqual(store.selectedID, another.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Media/\(id.uuidString)/LiveChunks").path))
        XCTAssertEqual(try AVAudioFile(forReading: URL(fileURLWithPath: record.localMediaPath!)).length, 11200)
        let reloaded = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        XCTAssertEqual(reloaded.recordings.first { $0.id == id }?.title, record.title)
    }

    @MainActor
    func testASRFailureStopsMicrophoneAndRetryPreservesTitle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        LiveASRProtocol.reset(status: 401)
        let recorder = TestLiveRecorder()
        let store = makeStore(directory: directory, recorder: recorder)
        store.startLiveRecording()
        try await waitUntil { store.liveSession?.phase == .recording }
        let id = try XCTUnwrap(store.liveSession?.id)
        store.renameSelected("失败后保留的标题")
        recorder.append(seconds: 0.5)
        try await waitUntil { store.liveSession == nil }
        XCTAssertFalse(recorder.started)
        XCTAssertEqual(store.selected?.status, .failed)
        XCTAssertTrue(store.selected?.errorMessage?.contains("API Key") == true)
        XCTAssertEqual(store.selected?.title, "失败后保留的标题")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.selected!.localMediaPath!))
        LiveASRProtocol.reset()
        store.retryTranscription(for: id)
        try await waitUntil { store.processingID == nil }
        XCTAssertEqual(store.selected?.status, .ready)
        XCTAssertEqual(store.selected?.segments.count, 1)
        XCTAssertEqual(store.selected?.title, "失败后保留的标题")
    }

    @MainActor
    func testSilenceIsAllowedDuringLiveTranscription() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        LiveASRProtocol.reset(body: #"{"output":{"sentences":[]}}"#)
        let recorder = TestLiveRecorder()
        let store = makeStore(directory: directory, recorder: recorder)
        store.startLiveRecording()
        try await waitUntil { store.liveSession?.phase == .recording }
        recorder.append(seconds: 0.5)
        try await waitUntil { (store.liveSession?.transcribedDuration ?? 0) > 0 }
        XCTAssertEqual(store.liveSession?.phase, .recording)
        XCTAssertTrue(store.selected!.segments.isEmpty)
        store.stopLiveRecording()
        try await waitUntil { store.liveSession == nil }
        XCTAssertEqual(store.selected?.status, .ready)
        XCTAssertNil(store.selected?.errorMessage)
    }

    @MainActor
    func testCancellingRemainingTranscriptionPreservesFullRecordingAndTitle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        LiveASRProtocol.reset(paused: true)
        let recorder = TestLiveRecorder()
        let store = makeStore(directory: directory, recorder: recorder)
        store.startLiveRecording()
        try await waitUntil { store.liveSession?.phase == .recording }
        let id = try XCTUnwrap(store.liveSession?.id)
        store.renameSelected("取消后保留的标题")
        recorder.append(seconds: 0.5)
        try await waitUntil { LiveASRProtocol.requestCount > 0 }
        recorder.append(seconds: 0.2)
        store.stopLiveRecording()
        XCTAssertEqual(store.liveSession?.phase, .finishing)
        store.cancelLiveTranscription()
        try await waitUntil { store.liveSession == nil }
        XCTAssertEqual(store.selected?.status, .failed)
        XCTAssertEqual(store.selected?.title, "取消后保留的标题")
        XCTAssertEqual(store.selected!.duration, 0.7, accuracy: 0.0001)
        XCTAssertEqual(try AVAudioFile(forReading: URL(fileURLWithPath: store.selected!.localMediaPath!)).length, 11200)
        let reloaded = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        XCTAssertEqual(reloaded.recordings.first { $0.id == id }?.title, "取消后保留的标题")
    }

    @MainActor
    func testCancellingPreparationCreatesNoRecordAndNeverStartsCapture() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = TestLiveRecorder()
        let store = makeStore(directory: directory, recorder: recorder)
        let before = store.recordings
        store.startLiveRecording()
        store.cancelLiveTranscription()
        try await waitUntil { store.liveSession == nil }
        XCTAssertEqual(store.recordings, before)
        XCTAssertFalse(recorder.started)
        XCTAssertNil(store.alertMessage)
    }

    @MainActor
    func testDeletingLiveRecordingCancelsPendingRecognitionAndRemovesMedia() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        LiveASRProtocol.reset(paused: true)
        let recorder = TestLiveRecorder()
        let store = makeStore(directory: directory, recorder: recorder)
        store.startLiveRecording()
        try await waitUntil { store.liveSession?.phase == .recording }
        let id = try XCTUnwrap(store.liveSession?.id)
        recorder.append(seconds: 0.5)
        try await waitUntil { LiveASRProtocol.requestCount > 0 }
        await store.deleteRecording(id)
        XCTAssertNil(store.liveSession)
        XCTAssertFalse(recorder.started)
        XCTAssertFalse(store.recordings.contains { $0.id == id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Media/\(id.uuidString)").path))
        XCTAssertFalse(AppStore(directory: directory, initialConfiguration: ProcessingConfiguration()).recordings.contains { $0.id == id })
    }

    @MainActor
    private func makeStore(directory: URL, recorder: TestLiveRecorder) -> AppStore {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [LiveASRProtocol.self]
        let engine = ProcessingEngine(session: URLSession(configuration: sessionConfig))
        var config = ProcessingConfiguration(provider: .dashScope)
        config.baseURL = "https://live-asr.example/api/v1"; config.apiKey = "test-live-key"
        return AppStore(engine: engine, directory: directory, initialConfiguration: config, liveRecorder: recorder)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= deadline { throw ProcessingFailure.message("Timed out waiting for live recording") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func buffer(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        liveTestBuffer(seconds: seconds, format: format)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RustleLive-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
private final class TestLiveRecorder: LiveRecordingCapturing {
    var authorized = true
    private(set) var started = false
    private var writer: LiveAudioWriter?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    func requestPermission() async -> Bool { authorized }
    func start(in directory: URL, progress: @escaping @Sendable (LiveRecordingProgress) -> Void) throws -> AsyncThrowingStream<LiveAudioChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<LiveAudioChunk, Error>.makeStream()
        writer = try LiveAudioWriter(directory: directory, format: format, interval: 0.5, continuation: continuation, progress: progress)
        started = true
        return stream
    }
    func append(seconds: Double) { writer?.append(liveTestBuffer(seconds: seconds, format: format)) }
    @discardableResult func stop() -> TimeInterval {
        let duration = writer?.finish() ?? 0
        writer = nil; started = false
        return duration
    }
}

private func liveTestBuffer(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount((seconds * format.sampleRate).rounded())
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / format.sampleRate) * 0.1) }
    return buffer
}

private final class LiveASRProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var paused = false
    private static var body = ""
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset(status: Int = 200, paused: Bool = false, body: String = #"{"output":{"sentence":{"sentence_id":0,"sentence_end":true,"begin_time":0,"end_time":100,"text":"识别到的语音"}}}"#) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; self.paused = paused; self.body = body; count = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "live-asr.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let status = Self.status, paused = Self.paused, body = Self.body
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !paused { client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
