import Foundation
import Network
import XCTest
@testable import Rustle

final class WhisperModelDownloaderTests: XCTestCase {
    private let fixture = WhisperModelDefinition(id: "fixture", title: "Fixture", sizeLabel: "3 bytes", sha1: "a9993e364706816aba3e25717850c26c9cd0d89d")

    func testCatalogUsesValidPublishedChecksumsAndDistinctFilenames() {
        XCTAssertEqual(Set(WhisperModelDefinition.catalog.map(\.filename)).count, WhisperModelDefinition.catalog.count)
        XCTAssertTrue(WhisperModelDefinition.catalog.allSatisfy { $0.sha1.count == 40 && $0.sha1.allSatisfy(\.isHexDigit) && !$0.id.contains(".en") })
    }

    func testDownloadSourcesUseSameModelAndHonorFallbackOrder() throws {
        let model = WhisperModelDefinition.catalog[2]
        XCTAssertEqual(try WhisperDownloadSource.huggingFace.url(for: model).absoluteString, "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")
        XCTAssertEqual(try WhisperDownloadSource.hfMirror.url(for: model).absoluteString, "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")
        XCTAssertEqual(WhisperDownloadSource.hfMirror.fallbackSources(enabled: true), [.hfMirror, .huggingFace])
        XCTAssertEqual(WhisperDownloadSource.huggingFace.fallbackSources(enabled: false), [.huggingFace])
        XCTAssertEqual(WhisperDownloadSource.custom.fallbackSources(enabled: true), [.custom])
    }

    func testCustomSourceAcceptsTemplatesDirectoriesAndDirectLinks() throws {
        for address in ["https://models.example/{filename}", "https://models.example", "https://models.example/", "https://models.example/ggml-fixture.bin"] {
            XCTAssertEqual(try WhisperDownloadSource.custom.url(for: fixture, customAddress: address).absoluteString, "https://models.example/ggml-fixture.bin")
        }
        XCTAssertEqual(try WhisperDownloadSource.custom.url(for: fixture, customAddress: "http://127.0.0.1:9876/{filename}").scheme, "http")
        for address in ["", "file:///tmp/models", "http://models.example", "https://user:password@models.example", "https://models.example/model.bin#fragment"] {
            XCTAssertThrowsError(try WhisperDownloadSource.custom.url(for: fixture, customAddress: address))
        }
        let invalid = WhisperModelDefinition(id: "../outside", title: "invalid", sizeLabel: "", sha1: fixture.sha1)
        XCTAssertThrowsError(try WhisperDownloadSource.huggingFace.url(for: invalid))
    }

    func testStreamingChecksumAndVerifiedReplacement() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent(".test.download")
        try Data("abc".utf8).write(to: staged)
        let digest = try await WhisperModelDownloader.checksum(of: staged)
        XCTAssertEqual(digest, fixture.sha1)
        let old = directory.appendingPathComponent(fixture.filename)
        try Data("previous model".utf8).write(to: old)
        let installed = try await WhisperModelDownloader.installVerifiedFile(staged, model: fixture, directory: directory)
        XCTAssertEqual(installed, old)
        XCTAssertEqual(try Data(contentsOf: installed), Data("abc".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testChecksumMismatchPreservesExistingModel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent(fixture.filename)
        try Data("existing".utf8).write(to: old)
        let staged = directory.appendingPathComponent("bad.download")
        try Data("invalid download".utf8).write(to: staged)
        do { _ = try await WhisperModelDownloader.installVerifiedFile(staged, model: fixture, directory: directory); XCTFail("Expected checksum rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("校验未通过")) }
        XCTAssertEqual(try Data(contentsOf: old), Data("existing".utf8))
    }

    func testRealHTTPDownloadIsVerifiedAndProgressIsReported() async throws {
        let server = try await LoopbackModelServer.start(body: Data("abc".utf8))
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = DownloadReportBox()
        let installed = try await WhisperModelDownloader().download(fixture, from: server.url, directory: directory) { reports.add($0) }
        XCTAssertEqual(try Data(contentsOf: installed), Data("abc".utf8))
        XCTAssertTrue(reports.sawVerification)
        XCTAssertEqual(reports.receivedBytes, 3)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasSuffix(".download") }))
    }

    func testHTTP404DoesNotReplaceAnExistingModel() async throws {
        let server = try await LoopbackModelServer.start(body: Data("not found".utf8), status: 404)
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent(fixture.filename)
        try Data("existing".utf8).write(to: old)
        do { _ = try await WhisperModelDownloader().download(fixture, from: server.url, directory: directory); XCTFail("Expected 404") }
        catch { XCTAssertTrue(error.localizedDescription.contains("404")) }
        XCTAssertEqual(try Data(contentsOf: old), Data("existing".utf8))
    }

    func testCancelledDownloadDoesNotInstallOrLeavePartialFiles() async throws {
        let server = try await LoopbackModelServer.start(body: Data("abc".utf8), delay: 2)
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = fixture
        let task = Task { try await WhisperModelDownloader().download(model, from: server.url, directory: directory) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testMediaHTTPDownloadReportsBytesAndCleansCancelledTransfers() async throws {
        let server = try await LoopbackModelServer.start(body: Data("abc".utf8))
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = ProgressEventBox()
        let mediaURL = server.url.deletingLastPathComponent().appendingPathComponent("sample.wav")
        let media = try await ProcessingEngine().prepareMedia(from: mediaURL, destinationDirectory: directory) { reports.add($0) }
        XCTAssertEqual(try Data(contentsOf: media.url), Data("abc".utf8))
        XCTAssertEqual(media.title, "sample")
        XCTAssertTrue(reports.values.contains { $0.fraction == 1 && $0.detail.contains("3") })
        let slow = try await LoopbackModelServer.start(body: Data("abc".utf8), delay: 2)
        defer { slow.stop() }
        let task = Task { try await ProcessingEngine().prepareMedia(from: slow.url, destinationDirectory: directory) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    @MainActor
    func testLinkTitleUsesServerFilenameAndPersistsEvenWhenTranscriptionFails() async throws {
        let server = try await LoopbackModelServer.start(body: Data("invalid media".utf8), headers: "Content-Disposition: attachment; filename=\"Video Interview.mp4\"\r\n")
        defer { server.stop() }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("[]".utf8).write(to: directory.appendingPathComponent("library.json"))
        let store = AppStore(directory: directory, initialConfiguration: ProcessingConfiguration(provider: .dashScope, apiKey: "unit-test-not-real"))
        store.importLink(server.url.absoluteString)
        let deadline = Date().addingTimeInterval(5)
        while store.recordings.isEmpty || store.processingID != nil {
            guard Date() < deadline else { XCTFail("Import did not finish"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.selected?.title, "Video Interview")
        XCTAssertEqual(store.selected?.status, .failed)
        let saved = try JSONDecoder().decode([Recording].self, from: Data(contentsOf: directory.appendingPathComponent("library.json")))
        XCTAssertEqual(saved.first?.title, "Video Interview")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class DownloadReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var verifying = false
    private var received: Int64 = 0
    var sawVerification: Bool { lock.lock(); defer { lock.unlock() }; return verifying }
    var receivedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return received }
    func add(_ update: ModelDownloadUpdate) {
        lock.lock(); defer { lock.unlock() }
        switch update { case .verifying: verifying = true; case .downloading(let bytes, _): received = bytes }
    }
}

private final class LoopbackModelServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "Rustle.ModelDownloadTestServer")
    private var connections: [NWConnection] = []
    private var signalledStart = false // Only accessed on the listener's serial queue.
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/model.bin")! }
    private init() throws { listener = try NWListener(using: .tcp, on: .any) }
    static func start(body: Data, status: Int = 200, delay: Double = 0, headers extraHeaders: String = "") async throws -> LoopbackModelServer {
        let server = try LoopbackModelServer()
        server.listener.newConnectionHandler = { connection in
            server.connections.append(connection)
            connection.start(queue: server.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                let headers = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\n\(extraHeaders)Connection: close\r\n\r\n"
                server.queue.asyncAfter(deadline: .now() + delay) {
                    connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                guard !server.signalledStart else { return }
                switch state {
                case .ready: server.signalledStart = true; continuation.resume()
                case .failed(let error): server.signalledStart = true; continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }
    func stop() {
        queue.async { self.listener.newConnectionHandler = nil; self.connections.forEach { $0.cancel() }; self.connections.removeAll(); self.listener.cancel() }
    }
}
