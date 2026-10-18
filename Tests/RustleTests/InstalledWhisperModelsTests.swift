import Foundation
import XCTest
@testable import Rustle

final class InstalledWhisperModelsTests: XCTestCase {
    @MainActor
    func testDefaultUsesFullLargeModelAndPreservesSavedSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RustleDefaultModel-\(UUID().uuidString)")
        let suite = "RustleDefaultModel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let directory = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent("ggml-base.bin")
        let large = directory.appendingPathComponent("ggml-large-v3.bin")
        for name in ["ggml-large-v3-turbo.bin", "ggml-small.bin", "ggml-base.bin", "ggml-large-v3.bin", "ggml-large-v3-turbo-q5_0.bin"] {
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        let manager = WhisperModelManager(directory: directory)
        XCTAssertEqual(manager.defaultModelURL(), large)
        XCTAssertEqual(manager.selectedModel.id, "large-v3")

        let automatic = AppStore(directory: root, defaults: defaults)
        XCTAssertEqual(automatic.configuration.whisperModelPath, large.path)
        defaults.set(base.path, forKey: "whisperModelPath")
        let manual = AppStore(directory: root, defaults: defaults)
        XCTAssertEqual(manual.configuration.whisperModelPath, base.path)
        let missing = directory.appendingPathComponent("missing.bin").path
        defaults.set(missing, forKey: "whisperModelPath")
        let unavailable = AppStore(directory: root, defaults: defaults)
        XCTAssertEqual(unavailable.configuration.whisperModelPath, missing)
    }

    @MainActor
    func testDownloadedAndSiblingModelsAppearAndLinksDoNotDuplicate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RustlePicker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloaded = root.appendingPathComponent("Models", isDirectory: true)
        let custom = root.appendingPathComponent("Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let small = downloaded.appendingPathComponent("ggml-small.bin")
        let base = custom.appendingPathComponent("ggml-base.bin")
        let tiny = custom.appendingPathComponent("ggml-tiny.bin")
        for url in [small, base, tiny] { try Data([1]).write(to: url) }
        try Data().write(to: custom.appendingPathComponent("empty.bin"))
        try FileManager.default.createDirectory(at: custom.appendingPathComponent("folder.bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: custom.appendingPathComponent("small-link.bin"), withDestinationURL: small)
        let manager = WhisperModelManager(directory: downloaded)
        let options = manager.installedModels(configuredPath: base.path)
        XCTAssertTrue(options.contains { $0.url.path == base.path && $0.title == "Base · 入门" })
        XCTAssertTrue(options.contains { $0.url.path == tiny.path })
        XCTAssertTrue(options.contains { $0.url.path == small.path })
        let local = options.filter { $0.url.path.hasPrefix(root.path + "/") }
        XCTAssertEqual(local.count, 3)
        XCTAssertEqual(Set(local.map { $0.url.resolvingSymlinksInPath().path }).count, 3)
    }

    @MainActor
    func testStorageChangeRefreshesDownloadedModelListWithoutStalePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RustleModelLocation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Old/Models", isDirectory: true)
        let new = root.appendingPathComponent("New/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let oldModel = old.appendingPathComponent("ggml-small.bin")
        let newModel = new.appendingPathComponent("ggml-tiny.bin")
        try Data([1]).write(to: oldModel)
        try Data([2]).write(to: newModel)
        let manager = WhisperModelManager(directory: old)
        manager.changeStorageDirectory(to: new)
        let options = manager.installedModels(configuredPath: "")
        XCTAssertTrue(options.contains { $0.url.path == newModel.path })
        XCTAssertFalse(options.contains { $0.url.path == oldModel.path })
    }
}
