import Foundation
import XCTest
@testable import Rustle

final class StorageLocationTests: XCTestCase {
    @MainActor
    func testStorageChangePreservesDataAndReloadsFromNewLocation() async throws {
        let root = temporaryDirectory()
        let suite = "RustleStorageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("Original", isDirectory: true)
        let target = root.appendingPathComponent("New Rustle", isDirectory: true)
        let store = AppStore(directory: source, initialConfiguration: ProcessingConfiguration(), defaults: defaults)
        var record = DemoContent.recordings[0]
        record.isDemo = false
        let media = source.appendingPathComponent("Media/\(record.id.uuidString)/sample.wav")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("media fixture".utf8).write(to: media)
        record.localMediaPath = media.path
        record.sourceURL = root.appendingPathComponent("original.wav").absoluteString
        store.recordings = [record]; store.selectedID = record.id
        let model = source.appendingPathComponent("Models/ggml-small.bin")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: model)
        store.configuration.whisperModelPath = model.path
        store.configuration.insightsAPIKey = "test-storage-key"
        XCTAssertTrue(store.saveSettings())
        XCTAssertTrue(store.save())
        let oldLibrary = try Data(contentsOf: source.appendingPathComponent("library.json"))
        let changed = await store.changeStorageLocation(to: target)
        XCTAssertTrue(changed, store.storageMigrationError ?? "")
        XCTAssertEqual(store.dataDirectory.path, target.path)
        XCTAssertFalse(store.isMigratingStorage)
        XCTAssertEqual(store.modelManager.directory.path, target.appendingPathComponent("Models").path)
        let newMedia = target.appendingPathComponent("Media/\(record.id.uuidString)/sample.wav")
        XCTAssertEqual(store.selected?.localMediaPath, newMedia.path)
        XCTAssertEqual(try Data(contentsOf: newMedia), Data("media fixture".utf8))
        XCTAssertEqual(store.configuration.whisperModelPath, target.appendingPathComponent("Models/ggml-small.bin").path)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("library.json")), oldLibrary)
        XCTAssertEqual(try CredentialStorage(directory: target).read().insightsKey, "test-storage-key")
        let permissions = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("Credentials/api-keys.json").path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let reloaded = AppStore(defaults: defaults)
        XCTAssertEqual(reloaded.dataDirectory.path, target.path)
        XCTAssertEqual(reloaded.recordings.map(\.id), [record.id])
        XCTAssertEqual(reloaded.selected?.localMediaPath, newMedia.path)
        XCTAssertEqual(reloaded.selected?.sourceURL, record.sourceURL)
        XCTAssertEqual(reloaded.configuration.insightsAPIKey, "test-storage-key")
        XCTAssertEqual(reloaded.configuration.whisperModelPath, store.configuration.whisperModelPath)
        store.renameSelected("保存到新位置")
        let saved = try JSONDecoder().decode([Recording].self, from: Data(contentsOf: target.appendingPathComponent("library.json")))
        XCTAssertEqual(saved.first?.title, "保存到新位置")
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("library.json")), oldLibrary)
    }

    @MainActor
    func testSavedModelPathFollowsMigrationWhenCurrentSelectionHasUnsavedChanges() async throws {
        let root = temporaryDirectory()
        let suite = "RustleSavedModelMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let target = root.appendingPathComponent("Target", isDirectory: true)
        let store = AppStore(directory: source, initialConfiguration: ProcessingConfiguration(), defaults: defaults)
        let savedModel = source.appendingPathComponent("Models/ggml-base.bin")
        try FileManager.default.createDirectory(at: savedModel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: savedModel)
        store.configuration.whisperModelPath = savedModel.path
        XCTAssertTrue(store.saveSettings())
        let external = root.appendingPathComponent("external-model.bin")
        try Data([2]).write(to: external)
        store.configuration.whisperModelPath = external.path
        let changed = await store.changeStorageLocation(to: target)
        XCTAssertTrue(changed)
        XCTAssertEqual(store.configuration.whisperModelPath, external.path)
        XCTAssertEqual(defaults.string(forKey: "whisperModelPath"), target.appendingPathComponent("Models/ggml-base.bin").path)
    }

    @MainActor
    func testExistingTargetIsNeverOverwrittenAndLocationDoesNotChange() async throws {
        let root = temporaryDirectory()
        let suite = "RustleStorageFailure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let target = root.appendingPathComponent("Target", isDirectory: true)
        let store = AppStore(directory: source, initialConfiguration: ProcessingConfiguration(), defaults: defaults)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let existing = target.appendingPathComponent("library.json")
        try Data("do not replace".utf8).write(to: existing)
        let ids = store.recordings.map(\.id)
        let changed = await store.changeStorageLocation(to: target)
        XCTAssertFalse(changed)
        XCTAssertEqual(store.dataDirectory.path, source.path)
        XCTAssertEqual(store.recordings.map(\.id), ids)
        XCTAssertNil(defaults.string(forKey: LibraryStorageMigration.preferenceKey))
        XCTAssertNotNil(store.storageMigrationError)
        XCTAssertEqual(try Data(contentsOf: existing), Data("do not replace".utf8))
        XCTAssertFalse(store.isMigratingStorage)
    }

    func testOverlappingAndAliasedDirectoriesAreRejected() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        var targets = [source, source.appendingPathComponent("Child"), root, alias.appendingPathComponent("Child")]
        let alternateCase = root.appendingPathComponent("source", isDirectory: true)
        if FileManager.default.fileExists(atPath: alternateCase.path) { targets.append(alternateCase.appendingPathComponent("Child")) }
        for target in targets {
            do {
                _ = try await LibraryStorageMigration.migrate(from: source, to: target, recordings: [])
                XCTFail("Expected overlap rejection")
            } catch { XCTAssertTrue(error.localizedDescription.contains("新位置"), target.path + ": " + error.localizedDescription) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), [])
    }

    func testExternalPathsAndMatchingSiblingPrefixesStayUnchanged() {
        let source = URL(fileURLWithPath: "/tmp/Rustle", isDirectory: true)
        let target = URL(fileURLWithPath: "/tmp/New Rustle", isDirectory: true)
        XCTAssertEqual(LibraryStorageMigration.relocatedPath("/tmp/Rustle/Media/a.wav", from: source, to: target), "/tmp/New Rustle/Media/a.wav")
        XCTAssertEqual(LibraryStorageMigration.relocatedPath("/tmp/Rustle-other/a.wav", from: source, to: target), "/tmp/Rustle-other/a.wav")
        XCTAssertEqual(LibraryStorageMigration.relocatedPath("/external/model.bin", from: source, to: target), "/external/model.bin")
        XCTAssertEqual(LibraryStorageMigration.relocatedPath("", from: source, to: target), "")
    }

    func testFailedCopyLeavesNoPartialDestinationOrStage() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Missing Source")
        let target = root.appendingPathComponent("Target")
        do {
            _ = try await LibraryStorageMigration.migrate(from: source, to: target, recordings: [])
            XCTFail("Expected failed copy")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    @MainActor
    func testStorageCannotChangeWhileImportPreflightIsPending() async throws {
        let root = temporaryDirectory()
        let suite = "RustleStorageBusy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        var config = ProcessingConfiguration()
        config.whisperExecutablePath = "/missing-whisper-cli"
        let source = root.appendingPathComponent("Source")
        let store = AppStore(directory: source, initialConfiguration: config, defaults: defaults)
        store.importMedia([root.appendingPathComponent("sample.wav")])
        let changed = await store.changeStorageLocation(to: root.appendingPathComponent("Target"))
        XCTAssertFalse(changed)
        XCTAssertTrue(store.storageMigrationError?.contains("请等待") == true)
        XCTAssertEqual(store.dataDirectory.path, source.path)
        // Allow the deliberately missing runtime to finish its preflight before cleanup.
        for _ in 0..<200 {
            if store.showSettingsSheet { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.showSettingsSheet)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RustleStorageTests-\(UUID().uuidString)", isDirectory: true)
    }
}
