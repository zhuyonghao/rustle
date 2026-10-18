import XCTest
import Foundation
@testable import Rustle

final class TranscriptTimelineTests: XCTestCase {
    func testRepairKeepsIDsDistinctSpeakersAndLaterRepetition() {
        let first = TranscriptSegment(start: 0.6, duration: 12, text: "开头。")
        let second = TranscriptSegment(start: 12.6, duration: 5.16, text: "第二句。")
        let quote = TranscriptSegment(start: 49.46, duration: 0.01, text: "”")
        let expanded = TranscriptSegment(start: 49.46, duration: 6.33, text: "”完整后文。")
        let repeatedLater = TranscriptSegment(start: 70, duration: 12, text: first.text)
        let anotherSpeaker = TranscriptSegment(start: first.start, duration: first.duration, text: first.text, speaker: "第二人")
        let duplicate = TranscriptSegment(start: first.start, duration: first.duration, text: first.text)
        let input = [first, second, quote, duplicate, second, expanded, repeatedLater, anotherSpeaker]
        let result = TranscriptSegment.mergingCumulativeResults(input)
        XCTAssertEqual(result, [first, anotherSpeaker, second, expanded, repeatedLater])
        XCTAssertEqual(TranscriptSegment.mergingCumulativeResults(result), result)
    }

    @MainActor
    func testExistingLibraryIsRepairedBackedUpAndNotMigratedAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = TranscriptSegment(start: 0.6, duration: 12, text: "开头。")
        let last = TranscriptSegment(start: 49.46, duration: 6.33, text: "后文。")
        let record = Recording(title: "累计结果", duration: 60, sourceKind: .audio,
            segments: [last, first, first, last],
            insights: MeetingInsights(summary: "已生成摘要", keyPoints: [], tasks: [], isAIGenerated: true))
        let original = try JSONEncoder().encode([record])
        let library = directory.appendingPathComponent("library.json")
        try original.write(to: library)
        let store = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        XCTAssertEqual(store.recordings[0].segments, [first, last])
        XCTAssertEqual(store.recordings[0].insights, record.insights)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backups = files.filter { $0.lastPathComponent.hasPrefix("library-before-timeline-repair-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), original)
        let saved = try JSONDecoder().decode([Recording].self, from: Data(contentsOf: library))
        XCTAssertEqual(saved[0].segments, [first, last])
        let reloaded = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        XCTAssertEqual(reloaded.recordings[0].segments, [first, last])
        let afterReload = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(afterReload.filter { $0.lastPathComponent.hasPrefix("library-before-timeline-repair-") }.count, 1)
    }
}
