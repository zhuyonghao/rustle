import Foundation
import XCTest
@testable import Rustle

final class MediaProgressTests: XCTestCase {
    func testPlatformTitlePreservesUnicodePunctuationAndFileLikeSuffixes() throws {
        let expected = "中文访谈：\"创作 / 思考\" 🎬.mp4"
        let encoded = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        XCTAssertEqual(MediaProgressParser.mediaTitle(MediaProgressParser.titlePrefix + encoded), expected)
        XCTAssertEqual(MediaProgressParser.mediaTitle(#"__RUSTLE_TITLE__"  视频标题  ""#), "视频标题")
        for line in ["diagnostic", "__RUSTLE_TITLE__not json", "__RUSTLE_TITLE__null", #"__RUSTLE_TITLE__"   ""#, #"__RUSTLE_TITLE__"NA""#] {
            XCTAssertNil(MediaProgressParser.mediaTitle(line))
        }
    }

    func testPlatformErrorsDistinguishNetworkInterruptionWithoutExposingDiagnostics() {
        let interrupted = ProcessingEngine.platformDownloadError("ERROR: connection reset https://cdn.example/private?token=secret")
        XCTAssertTrue(interrupted.contains("连接中断"))
        XCTAssertFalse(interrupted.contains("secret"))
        XCTAssertTrue(ProcessingEngine.platformDownloadError("HTTP Error 429").contains("限制下载频率"))
        XCTAssertTrue(ProcessingEngine.platformDownloadError("HTTP Error 403").contains("拒绝"))
    }

    func testDownloadProgressHandlesUnknownAndEstimatedTotals() {
        let unknown = MediaProgressParser.download(#"__RUSTLE_DOWNLOAD__{"downloaded_bytes":2048,"total_bytes":0,"speed":512,"eta":0}"#)
        XCTAssertNil(unknown?.fraction)
        XCTAssertTrue(unknown?.detail.contains("总大小未知") == true)
        let estimated = MediaProgressParser.download(#"__RUSTLE_DOWNLOAD__{"downloaded_bytes":50,"total_bytes":0,"total_bytes_estimate":200}"#)
        XCTAssertEqual(estimated?.fraction, 0.25)
        XCTAssertTrue(estimated?.detail.contains("约") == true)
        XCTAssertNil(MediaProgressParser.download("[download] diagnostic"))
        XCTAssertNil(MediaProgressParser.download(#"__RUSTLE_DOWNLOAD__{"downloaded_bytes":-2}"#))
        XCTAssertEqual(MediaProgressParser.filepath(#"__RUSTLE_FILE__"/tmp/中文 file.m4a""#), "/tmp/中文 file.m4a")
    }

    func testWhisperProgressIsGlobalAcrossChunksAndRejectsInvalidLogs() {
        XCTAssertEqual(MediaProgressParser.whisper("whisper_print_progress_callback: progress =  35%"), 0.35)
        XCTAssertNil(MediaProgressParser.whisper("progress = 200%"))
        XCTAssertNil(MediaProgressParser.whisper("model size = 35 MB"))
        let second = ProcessingProgress.transcription(offset: 600, chunkDuration: 300, duration: 900, fraction: 0.5)
        XCTAssertEqual(second.fraction, 750.0 / 900)
        XCTAssertTrue(second.detail.contains("第 2/2 段"))
        XCTAssertNil(ProcessingProgress.transcription(offset: 0, chunkDuration: 300, duration: 600, fraction: nil, local: false).fraction)
    }

    func testSubprocessStreamsBothPipesBeforeExitAndRetainsPartialUTF8() async throws {
        let events = ProgressEventBox()
        let start = Date()
        let result = try await StreamingProcess().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '\\344\\270'; sleep 0.1; printf '\\255\\346\\226\\207\\n'; printf 'progress = 35%%\\n' >&2; sleep 1"], timeout: 5) { line in
            events.add(.init(title: line), at: Date())
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(events.values.contains { $0.title == "中文" })
        XCTAssertTrue(events.values.contains { $0.title == "progress = 35%" })
        XCTAssertLessThan(events.firstDate!.timeIntervalSince(start), 0.9)
        XCTAssertGreaterThan(Date().timeIntervalSince(events.firstDate!), 0.8)
    }
}

final class ProgressEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProcessingProgress] = []
    private var first: Date?
    var values: [ProcessingProgress] { lock.lock(); defer { lock.unlock() }; return events }
    var firstDate: Date? { lock.lock(); defer { lock.unlock() }; return first }
    func add(_ value: ProcessingProgress, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        events.append(value); if first == nil { first = date }
    }
}
