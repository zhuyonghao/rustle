import XCTest
import Foundation
@testable import Rustle

final class RecordingDeletionTests: XCTestCase {
    @MainActor
    func testDeletionRemovesAllContentAndOwnedMediaButPreservesOriginalAndOtherRecords() async throws {
        try await withStore { store, directory in
            var record = DemoContent.recordings[0]
            record.contentInsights = ContentInsights(
                overview: ContentOverview(summary: "摘要", keyPoints: ["要点"]),
                mindMap: MindMapNode(title: "导图"), tasks: [ActionItem(title: "待办")],
                answers: [FollowUpAnswer(question: "问题", answer: "回答")],
                translation: SubtitleTranslation(language: .english, segments: record.segments)
            )
            let original = directory.appendingPathComponent("original.wav")
            try Data("original".utf8).write(to: original)
            record.sourceURL = original.absoluteString
            // Even an external localMediaPath must never authorize deleting an original.
            record.localMediaPath = original.path
            let other = DemoContent.recordings[1]
            store.recordings = [record, other]; store.selectedID = record.id
            let media = try createMedia(record.id, in: directory)
            let otherMedia = try createMedia(other.id, in: directory)
            XCTAssertTrue(store.save())

            await store.deleteRecording(record.id)

            XCTAssertEqual(store.recordings, [other])
            XCTAssertEqual(store.selectedID, other.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: otherMedia.path))
            XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
            let reloaded = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
            XCTAssertEqual(reloaded.recordings, [other])
        }
    }

    @MainActor
    func testDeletingUnselectedRecordPreservesCurrentSelection() async throws {
        try await withStore { store, _ in
            let selected = store.recordings[0]
            let target = store.recordings[1]
            store.selectedID = selected.id
            await store.deleteRecording(target.id)
            XCTAssertEqual(store.selectedID, selected.id)
            XCTAssertFalse(store.recordings.contains { $0.id == target.id })
        }
    }

    @MainActor
    func testDeletingLastVisibleAndLastRecordKeepsEmptyLibraryAfterReload() async throws {
        try await withStore { store, directory in
            var favorite = DemoContent.recordings[0]; favorite.isFavorite = true
            var other = DemoContent.recordings[1]; other.isFavorite = false
            store.recordings = [favorite, other]; store.selectedID = favorite.id
            store.filter = .favorites
            await store.deleteRecording(favorite.id)
            XCTAssertNil(store.selectedID)
            XCTAssertTrue(store.visibleRecordings.isEmpty)
            XCTAssertEqual(store.recordings, [other])
            await store.deleteRecording(other.id)
            let reloaded = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
            XCTAssertTrue(reloaded.recordings.isEmpty)
            XCTAssertNil(reloaded.selectedID)
        }
    }

    @MainActor
    func testSaveFailurePreservesRecordSelectionAndMedia() async throws {
        try await withStore { store, directory in
            let before = store.recordings
            let target = before[0]
            store.selectedID = target.id
            let media = try createMedia(target.id, in: directory)
            // An existing directory makes an atomic library write fail on every account.
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("library.json"), withIntermediateDirectories: true)
            await store.deleteRecording(target.id)
            XCTAssertEqual(store.recordings, before)
            XCTAssertEqual(store.selectedID, target.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
            XCTAssertNotNil(store.alertMessage)
        }
    }

    @MainActor
    func testDeletingActiveImportCancelsBatchAndCleansMediaAfterWriterStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RustleDeleteImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeletionDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = AppStore(engine: ProcessingEngine(session: session), directory: directory,
                             initialConfiguration: ProcessingConfiguration(provider: .dashScope))
        store.recordings = []; store.selectedID = nil
        store.importMedia([URL(string: "https://delete.example/first.mp3")!, URL(string: "https://delete.example/second.mp3")!])
        let deadline = Date().addingTimeInterval(3)
        while store.processingID == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard let id = store.processingID else { XCTFail("Import did not start"); return }
        let media = directory.appendingPathComponent("Media/\(id.uuidString)")
        while !FileManager.default.fileExists(atPath: media.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))

        await store.deleteRecording(id)

        XCTAssertNil(store.processingID)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
        let reloaded = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        XCTAssertTrue(reloaded.recordings.isEmpty)
    }

    @MainActor
    private func withStore(_ body: (AppStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RustleDeletionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration())
        try await body(store, directory)
    }

    private func createMedia(_ id: UUID, in directory: URL) throws -> URL {
        let media = directory.appendingPathComponent("Media/\(id.uuidString)")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: media.appendingPathComponent("copy.wav"))
        return media
    }
}

private final class DeletionDownloadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "audio/mpeg", "Content-Length": "1024"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 8))
        // Leave the download open until the record deletion cancels it.
    }
    override func stopLoading() {}
}
