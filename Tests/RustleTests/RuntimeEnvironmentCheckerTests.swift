import Foundation
import XCTest
@testable import Rustle

final class RuntimeEnvironmentCheckerTests: XCTestCase {
    func testHomebrewStyleDownloaderLinksAreFoundAndPassStartupCheck() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try fixture(directory)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        let libexec = directory.appendingPathComponent("libexec", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
        let target = libexec.appendingPathComponent("yt-dlp")
        try "#!/bin/sh\necho 2026.08.19\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        let intermediate = directory.appendingPathComponent("yt-dlp-link")
        try FileManager.default.createSymbolicLink(atPath: intermediate.path, withDestinationPath: "libexec/yt-dlp")
        let link = bin.appendingPathComponent("yt-dlp")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../yt-dlp-link")
        let resolved = ProcessingEngine.findDownloader(searchDirectories: [bin.path])
        XCTAssertEqual(resolved, link)
        let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: resolved)
        XCTAssertEqual(report.checks.first { $0.id == .downloader }?.status, .ready)
    }

    func testDownloaderRejectsBrokenLinksDirectoryLinksAndNonExecutables() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = directory.appendingPathComponent("yt-dlp")
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: target)
        XCTAssertNil(ProcessingEngine.findDownloader(searchDirectories: [directory.path]))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertNil(ProcessingEngine.findDownloader(searchDirectories: [directory.path]))
        try FileManager.default.removeItem(at: target)
        try Data("not executable".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        XCTAssertNil(ProcessingEngine.findDownloader(searchDirectories: [directory.path]))
    }

    func testWhisperExecutableAndModelLinksAlsoPassEnvironmentCheck() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = try fixture(directory)
        let executableLink = directory.appendingPathComponent("linked-whisper")
        let modelLink = directory.appendingPathComponent("linked-model.bin")
        try FileManager.default.createSymbolicLink(at: executableLink, withDestinationURL: URL(fileURLWithPath: config.whisperExecutablePath))
        try FileManager.default.createSymbolicLink(at: modelLink, withDestinationURL: URL(fileURLWithPath: config.whisperModelPath))
        config.whisperExecutablePath = executableLink.path
        config.whisperModelPath = modelLink.path
        XCTAssertEqual(LocalWhisperService.resolveExecutable(config.whisperExecutablePath), executableLink)
        XCTAssertEqual(LocalWhisperService.resolveModel(config.whisperModelPath), modelLink)
        let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testMissingExplicitPathsDoNotFallbackAndDownloaderIsOptional() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = ProcessingConfiguration()
        config.whisperExecutablePath = directory.appendingPathComponent("missing-cli").path
        config.whisperModelPath = directory.appendingPathComponent("missing.bin").path
        let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil)
        XCTAssertEqual(report.failures.map(\.id), [.whisper, .model])
        XCTAssertEqual(report.checks.first { $0.id == .downloader }?.status, .optional)
        XCTAssertFalse(report.checks.first { $0.id == .downloader }!.blocksTranscription)
    }

    func testUsableRuntimePassesAndStorageProbeIsRemoved() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try fixture(directory)
        let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.checks.first { $0.id == .storage }?.status, .ready)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".environment-check-") })
    }

    func testBrokenDependencyAndWrongExecutableInterfaceAreRejected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try fixture(directory)
        for script in ["#!/bin/sh\nexit 127\n", "#!/bin/sh\necho unrelated-program\n"] {
            try script.write(toFile: config.whisperExecutablePath, atomically: false, encoding: .utf8)
            let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil)
            XCTAssertEqual(report.failures.map(\.id), [.whisper])
        }
    }

    func testInvalidAndTruncatedModelHeadersAreRejected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try fixture(directory)
        for bytes in [Data("download error page".utf8), Data([0x6c, 0x6d, 0x67, 0x67])] {
            try bytes.write(to: URL(fileURLWithPath: config.whisperModelPath))
            let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil)
            XCTAssertEqual(report.failures.map(\.id), [.model])
        }
    }

    func testEnglishModelMustMatchLanguage() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = try fixture(directory)
        let english = directory.appendingPathComponent("ggml-base.en.bin")
        try FileManager.default.copyItem(atPath: config.whisperModelPath, toPath: english.path)
        config.whisperModelPath = english.path
        var report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil)
        XCTAssertEqual(report.failures.map(\.id), [.model])
        config.localeIdentifier = "en-US"
        report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testCloudASRSkipsLocalWhisper() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = ProcessingConfiguration(provider: .dashScope)
        config.whisperExecutablePath = "/missing/whisper"
        config.whisperModelPath = "/missing/model"
        let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.checks.first { $0.id == .whisper }?.status, .skipped)
        XCTAssertEqual(report.checks.first { $0.id == .model }?.status, .skipped)
    }

    func testStorageFailurePreservesExistingFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("existing-file")
        try Data("preserved".utf8).write(to: file)
        let report = try await RuntimeEnvironmentChecker.check(configuration: .init(provider: .dashScope), directory: file, downloader: nil)
        XCTAssertEqual(report.failures.map(\.id), [.storage])
        XCTAssertEqual(try Data(contentsOf: file), Data("preserved".utf8))
    }

    func testHungExecutableTimesOutAndCancellationPropagates() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try fixture(directory)
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(toFile: config.whisperExecutablePath, atomically: false, encoding: .utf8)
        let started = Date()
        let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil, timeout: 0.1)
        XCTAssertEqual(report.failures.map(\.id), [.whisper])
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        let task = Task { try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: nil) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOptionalDownloaderMustActuallyLaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try fixture(directory)
        let downloader = directory.appendingPathComponent("yt-dlp")
        try "#!/bin/sh\nexit 127\n".write(to: downloader, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: downloader.path)
        let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: directory, downloader: downloader)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.checks.first { $0.id == .downloader }?.status, .optional)
    }

    @MainActor
    func testImportPreflightOpensSettingsBeforeCreatingRecord() async throws {
        let directory = temporaryDirectory()
        let suite = "RustleRuntimeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        var config = ProcessingConfiguration()
        config.whisperExecutablePath = directory.appendingPathComponent("missing").path
        let store = AppStore(directory: directory, initialConfiguration: config, defaults: defaults)
        let ids = store.recordings.map(\.id)
        store.importMedia([directory.appendingPathComponent("audio.wav")])
        for _ in 0..<200 {
            if store.showSettingsSheet { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.showSettingsSheet)
        XCTAssertEqual(store.recordings.map(\.id), ids)
        XCTAssertNil(store.processingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Media").path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RustleRuntimeTests-\(UUID().uuidString)")
    }

    private func fixture(_ directory: URL) throws -> ProcessingConfiguration {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("whisper with spaces")
        try "#!/bin/sh\necho '--model --output-json --print-progress'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = directory.appendingPathComponent("ggml-base.bin")
        try (Data([0x6c, 0x6d, 0x67, 0x67]) + Data(repeating: 0, count: 48)).write(to: model)
        var config = ProcessingConfiguration()
        config.whisperExecutablePath = executable.path
        config.whisperModelPath = model.path
        return config
    }
}
