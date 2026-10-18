import XCTest
@testable import Rustle

final class CredentialStorageTests: XCTestCase {
    func testMissingStorageReturnsEmptyKeysWithoutCreatingFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(try CredentialStorage(directory: directory).read(), APICredentials())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testBothKeysSurviveReloadAndReplacement() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CredentialStorage(directory: directory)
        let original = APICredentials(transcriptionKey: "test-transcription", insightsKey: "test-insights")
        try storage.save(original)
        XCTAssertEqual(try CredentialStorage(directory: directory).read(), original)
        let replacement = APICredentials(transcriptionKey: "", insightsKey: "test-new-insights")
        try storage.save(replacement)
        XCTAssertEqual(try CredentialStorage(directory: directory).read(), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Credentials").path), ["api-keys.json"])
    }

    func testClearingBothKeysRemovesFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CredentialStorage(directory: directory)
        try storage.save(APICredentials(transcriptionKey: "test-key"))
        try storage.save(APICredentials())
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialFile(directory).path))
        XCTAssertEqual(try storage.read(), APICredentials())
    }

    func testPermissionsAreRestrictedOnSaveReplacementAndRead() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CredentialStorage(directory: directory)
        let credentials = APICredentials(insightsKey: "test-key")
        let folder = directory.appendingPathComponent("Credentials")
        let file = credentialFile(directory)
        for _ in 0..<2 {
            try storage.save(credentials)
            XCTAssertEqual(try permissions(folder), 0o700)
            XCTAssertEqual(try permissions(file), 0o600)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try storage.read(), credentials)
        XCTAssertEqual(try permissions(folder), 0o700)
        XCTAssertEqual(try permissions(file), 0o600)
    }

    func testCorruptFileReportsErrorAndPreservesOriginal() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CredentialStorage(directory: directory)
        try storage.save(APICredentials(insightsKey: "test-key"))
        let corrupt = Data("invalid-json".utf8)
        try corrupt.write(to: credentialFile(directory))
        XCTAssertThrowsError(try storage.read())
        XCTAssertEqual(try Data(contentsOf: credentialFile(directory)), corrupt)
    }

    @MainActor
    func testSaveFailureKeepsSessionKeysAndReportsFailure() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ProcessingConfiguration(apiKey: "test-transcription", insightsAPIKey: "test-insights")
        let store = AppStore(directory: directory, initialConfiguration: configuration)
        // A regular file blocks creation of the credential directory even when run as root.
        try Data("blocked".utf8).write(to: directory.appendingPathComponent("Credentials"))
        XCTAssertFalse(store.saveSettings())
        XCTAssertEqual(store.configuration.apiKey, configuration.apiKey)
        XCTAssertEqual(store.configuration.insightsAPIKey, configuration.insightsAPIKey)
        XCTAssertNotNil(store.alertMessage)
        XCTAssertNil(store.toast)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RustleCredentialsTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func credentialFile(_ directory: URL) -> URL {
        directory.appendingPathComponent("Credentials/api-keys.json")
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
    }
}
