import Foundation
import XCTest
@testable import Rustle

final class RecordingCompatibilityTests: XCTestCase {
    func testLibrariesWithoutNotesAndLegacyTextKindsStillDecode() throws {
        let original = DemoContent.recordings[0]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "notes")
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.noteText, "")
        XCTAssertEqual(decoded.segments, original.segments)
        for kind in [SourceKind.legacyNote, .microphone] {
            let note = Recording(title: "新记录", duration: 0, sourceKind: kind, segments: [], notes: "我的笔记")
            XCTAssertEqual(try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(note)), note)
        }
    }

    func testLegacyNotesRemainExportableWithoutEnteringSubtitles() {
        var record = Recording(title: "文字笔记", duration: 0, sourceKind: .legacyNote, segments: [], notes: "重点 *原文*\n下一步")
        XCTAssertTrue(record.hasExportableContent)
        let markdown = TranscriptExporter.export(record, format: .markdown)
        XCTAssertTrue(markdown.contains("## 我的笔记"))
        XCTAssertTrue(markdown.contains("重点 *原文*"))
        XCTAssertFalse(markdown.contains("## 转写原文"))
        XCTAssertTrue(TranscriptExporter.export(record, format: .text).contains("重点 *原文*\n下一步"))
        XCTAssertEqual(TranscriptExporter.export(record, format: .srt), "")
        record.sourceKind = .microphone
        record.segments = [.init(start: 0, duration: 1, text: "语音原文")]
        XCTAssertTrue(TranscriptExporter.export(record, format: .markdown).contains("## 转写原文"))
        XCTAssertFalse(TranscriptExporter.export(record, format: .srt).contains("重点"))
    }

    @MainActor
    func testLoadingAndSavingEarlierNotesDoesNotDiscardTheirContent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = Recording(title: "旧文字记录", duration: 0, sourceKind: .legacyNote, segments: [], notes: "此前已保存的文字")
        var audio = DemoContent.recordings[0]
        audio.notes = "此前附加在音频中的文字"
        try JSONEncoder().encode([legacy, audio]).write(to: directory.appendingPathComponent("library.json"))
        let store = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        XCTAssertEqual(store.recordings.count, 2)
        XCTAssertEqual(store.selected?.sourceKind, .legacyNote)
        store.renameSelected("已重命名的记录")
        let reloaded = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        XCTAssertEqual(reloaded.recordings.first { $0.id == legacy.id }?.noteText, legacy.noteText)
        XCTAssertEqual(reloaded.recordings.first { $0.id == audio.id }?.noteText, audio.noteText)
        XCTAssertTrue(TranscriptExporter.export(reloaded.recordings[0], format: .text).contains(legacy.noteText))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RustleCompatibility-\(UUID().uuidString)", isDirectory: true)
    }
}
