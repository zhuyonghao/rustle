import XCTest
@testable import Rustle

final class TranscriptExporterTests: XCTestCase {
    func testSRTKeepsMillisecondsAndHourIntervals() {
        let recording = sample(segments: [
            TranscriptSegment(start: 3661.125, duration: 2.375, text: "跨过一小时的字幕", speaker: "林知夏"),
            TranscriptSegment(start: 59.75, duration: 0.5, text: "跨过一分钟")
        ])

        XCTAssertEqual(TranscriptExporter.export(recording, format: .srt), """
        1
        00:00:59,750 --> 00:01:00,250
        跨过一分钟

        2
        01:01:01,125 --> 01:01:03,500
        林知夏：跨过一小时的字幕

        """)
    }

    func testSRTKeepsEqualTimestampOrderAndRemovesEmptyCues() {
        let recording = sample(segments: [
            TranscriptSegment(start: 2, duration: 1, text: "第一句\r\n\r\n接着说"),
            TranscriptSegment(start: 2, duration: 2, text: "第二句"),
            TranscriptSegment(start: 3, duration: 1, text: " \n ")
        ])
        let output = TranscriptExporter.export(recording, format: .srt)

        XCTAssertEqual(output.components(separatedBy: " --> ").count - 1, 2)
        XCTAssertTrue(output.hasPrefix("1\n00:00:02,000 --> 00:00:03,000\n第一句\n接着说\n\n2\n"))
    }

    func testSRTSanitizesInvalidIntervals() {
        let recording = sample(segments: [TranscriptSegment(start: -.infinity, duration: -.infinity, text: "<b>原文</b>")])
        let output = TranscriptExporter.export(recording, format: .srt)

        XCTAssertTrue(output.contains("00:00:00,000 --> 00:00:00,001"))
        XCTAssertTrue(output.contains("&lt;b&gt;原文&lt;/b&gt;"))
        XCTAssertEqual(TranscriptExporter.export(sample(segments: []), format: .srt), "")
    }

    func testMarkdownIncludesInsightsTaskStateAndEscapedTranscript() {
        var recording = sample(segments: [TranscriptSegment(start: 8.25, duration: 2, text: "不是 *强调*，而是原始文本。", speaker: "陈一")])
        recording.title = "方案 [讨论]"
        recording.isDemo = true
        recording.insights = MeetingInsights(
            summary: "把想法变成行动。", keyPoints: ["保留原文"],
            tasks: [
                ActionItem(title: "完成方案", owner: "林知夏", dueDate: "10月16日", isCompleted: true),
                ActionItem(title: "安排测试", owner: "陈一")
            ]
        )
        let output = TranscriptExporter.export(recording, format: .markdown)

        XCTAssertTrue(output.hasPrefix("# 方案 \\[讨论\\]"))
        XCTAssertTrue(output.contains("演示内容"))
        XCTAssertTrue(output.contains("## 内容总结\n\n把想法变成行动。"))
        XCTAssertTrue(output.contains("- [x] 完成方案（负责人：林知夏；截止：10月16日）"))
        XCTAssertTrue(output.contains("- [ ] 安排测试"))
        XCTAssertTrue(output.contains("**00:08 – 00:10 · 陈一**"))
        XCTAssertTrue(output.contains("不是 \\*强调\\*，而是原始文本。"))
    }

    func testPlainTextIncludesOriginalTextAndCompleteState() {
        var recording = sample(segments: [TranscriptSegment(start: 0, duration: 3, text: "保留 *原文*。")])
        recording.insights = MeetingInsights(summary: "讨论总结", keyPoints: ["关注重点"], tasks: [ActionItem(title: "确认方案", isCompleted: true)], isAIGenerated: true)
        let output = TranscriptExporter.export(recording, format: .text)

        XCTAssertTrue(output.contains("[已完成] 确认方案"))
        XCTAssertTrue(output.contains("保留 *原文*。"))
        XCTAssertTrue(output.contains("[00:00 – 00:03]"))
        XCTAssertEqual(ExportFormat.allCases.map(\.fileExtension), ["md", "txt", "srt"])
    }

    func testDemosAreExplicitAndHaveConsistentIntervals() {
        let recordings = DemoContent.recordings
        XCTAssertEqual(recordings.count, 4)
        XCTAssertTrue(recordings.allSatisfy { $0.isDemo && $0.localMediaPath == nil && $0.sourceURL == nil })
        XCTAssertGreaterThanOrEqual(recordings[0].segments.count, 12)
        XCTAssertEqual(recordings[0].duration, 1472)
        for recording in recordings {
            XCTAssertTrue(recording.segments.allSatisfy { $0.start >= 0 && $0.duration > 0 && $0.start + $0.duration <= recording.duration })
            XCTAssertFalse(recording.insights?.summary.isEmpty ?? true)
        }
    }

    func testLegacyExtractsAreRemovedWithoutChangingTranscriptOrAPIInsights() throws {
        var record = sample(segments: [TranscriptSegment(start: 0, duration: 3, text: "原始文字")])
        record.localMediaPath = "/tmp/原始媒体.wav"
        record.insights = MeetingInsights(summary: "旧规则摘要", keyPoints: ["旧要点"], tasks: [ActionItem(title: "旧待办")])
        let before = record
        XCTAssertNil(record.apiInsights)
        XCTAssertFalse(TranscriptExporter.export(record, format: .markdown).contains("旧规则摘要"))
        XCTAssertFalse(TranscriptExporter.export(record, format: .text).contains("旧待办"))
        XCTAssertTrue(record.discardLegacyInsights())
        XCTAssertNil(record.insights)
        XCTAssertEqual(record.id, before.id)
        XCTAssertEqual(record.segments, before.segments)
        XCTAssertEqual(record.localMediaPath, before.localMediaPath)
        record.insights = MeetingInsights(summary: "API 摘要", keyPoints: [], tasks: [], isAIGenerated: true)
        XCTAssertFalse(record.discardLegacyInsights())
        XCTAssertEqual(record.apiInsights?.summary, "API 摘要")
        XCTAssertTrue(TranscriptExporter.export(record, format: .text).contains("API 摘要"))
        var demo = DemoContent.recordings[0]
        XCTAssertFalse(demo.discardLegacyInsights())
        XCTAssertNotNil(demo.apiInsights)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json.removeValue(forKey: "insightsError")
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.insightsError)
        XCTAssertEqual(decoded.insights, record.insights)
    }

    private func sample(segments: [TranscriptSegment]) -> Recording {
        Recording(title: "导出测试", createdAt: Date(timeIntervalSince1970: 0), duration: 4000, sourceKind: .audio, segments: segments)
    }
}
