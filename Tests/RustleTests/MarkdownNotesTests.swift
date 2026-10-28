import Foundation
import XCTest
@testable import Rustle

final class MarkdownNotesTests: XCTestCase {
    func testStandaloneNoteExportPreservesMarkdownWithoutEscapingOrAddingTranscript() {
        let markdown = "# 项目计划\n\n**重点** 与 [链接](https://example.com)\n\n- [ ] 下一步\n\n```swift\nlet value = 1\n```\n\n| 项目 | 状态 |\n| --- | --- |\n| 编辑器 | 完成 |"
        let record = Recording(title: "记录标题", duration: 12, sourceKind: .audio,
                               segments: [.init(start: 0, duration: 1, text: "不应出现在独立笔记导出中")], notes: markdown)
        let output = TranscriptExporter.noteMarkdown(record)
        XCTAssertEqual(output, markdown + "\n")
        XCTAssertFalse(output.contains("转写原文"))
        XCTAssertFalse(output.contains("记录标题"))
        XCTAssertFalse(output.contains("\\*"))
        let combined = TranscriptExporter.export(record, format: .markdown)
        XCTAssertTrue(combined.contains(markdown))
        XCTAssertTrue(combined.contains("## 转写原文"))
    }

    @MainActor
    func testMarkdownAutosavesAcrossRecordSwitchesWithoutChangingASROrInsights() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        let first = store.recordings[0], second = store.recordings[1]
        store.updateNotes(for: first.id, markdown: "# 第一条\n\n**重点**")
        store.selectedID = second.id
        store.updateNotes(for: second.id, markdown: "> 第二条记录\n\n- [x] 已确认")
        try await Task.sleep(for: .milliseconds(500))
        let reloaded = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        let firstSaved = try XCTUnwrap(reloaded.recordings.first { $0.id == first.id })
        let secondSaved = try XCTUnwrap(reloaded.recordings.first { $0.id == second.id })
        XCTAssertEqual(firstSaved.noteText, "# 第一条\n\n**重点**")
        XCTAssertEqual(secondSaved.noteText, "> 第二条记录\n\n- [x] 已确认")
        XCTAssertEqual(firstSaved.segments, first.segments)
        XCTAssertEqual(firstSaved.insights, first.insights)
        XCTAssertTrue(store.unsavedNoteIDs.isEmpty)
    }

    @MainActor
    func testSaveFailureKeepsMarkdownDraftUntilRetrySucceeds() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        let id = try XCTUnwrap(store.selectedID)
        let library = directory.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        store.updateNotes(for: id, markdown: "## 草稿\n\n保留 **格式**")
        XCTAssertFalse(store.save())
        XCTAssertEqual(store.selected?.noteText, "## 草稿\n\n保留 **格式**")
        XCTAssertTrue(store.unsavedNoteIDs.contains(id))
        try FileManager.default.removeItem(at: library)
        XCTAssertTrue(store.save())
        XCTAssertTrue(store.unsavedNoteIDs.isEmpty)
    }

    @MainActor
    func testClearingNotesAndTranscriptEditsPreserveIndependentResults() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        let record = try XCTUnwrap(store.selected)
        store.updateNotes(for: record.id, markdown: "手动 **笔记**")
        store.editSegment(record.segments[0].id, text: "修订后的转写")
        XCTAssertEqual(store.selected?.noteText, "手动 **笔记**")
        store.updateNotes(for: record.id, markdown: "")
        XCTAssertTrue(store.save())
        let reloaded = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        XCTAssertEqual(reloaded.recordings.first { $0.id == record.id }?.noteText, "")
        XCTAssertEqual(TranscriptExporter.noteMarkdown(reloaded.recordings[0]), "")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RustleMarkdown-\(UUID().uuidString)", isDirectory: true)
    }
}
