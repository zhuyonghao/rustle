import XCTest
import Foundation
@testable import Rustle

final class SettingsMigrationTests: XCTestCase {
    @MainActor
    func testRemovedServicesResetWithoutSendingOldKeysToNewEndpoints() throws {
        try withSettings { defaults, directory in
            defaults.set(true, forKey: "localASRMigration")
            defaults.set("OpenAI 兼容 API", forKey: "provider")
            defaults.set("https://old-asr.example/v1", forKey: "apiBaseURL")
            defaults.set("whisper-1", forKey: "transcriptionModel")
            defaults.set("Kimi API", forKey: "insightsProvider")
            defaults.set("https://api.moonshot.cn/v1", forKey: "insightsBaseURL")
            defaults.set("kimi-k2.6", forKey: "insightsModel")
            let storage = CredentialStorage(directory: directory)
            try storage.save(APICredentials(transcriptionKey: "old-asr-key", insightsKey: "old-content-key"))

            let store = AppStore(directory: directory, defaults: defaults)
            XCTAssertEqual(store.configuration.provider, .whisperCpp)
            XCTAssertEqual(store.configuration.baseURL, DashScopeASR.defaultBaseURL)
            XCTAssertEqual(store.configuration.transcriptionModel, DashScopeASR.defaultModel)
            XCTAssertEqual(store.configuration.insightsBaseURL, "https://api.openai.com/v1")
            XCTAssertEqual(store.configuration.summaryModel, "gpt-4o-mini")
            XCTAssertTrue(store.configuration.apiKey.isEmpty)
            XCTAssertTrue(store.configuration.insightsAPIKey.isEmpty)

            XCTAssertTrue(store.saveSettings())
            XCTAssertNil(defaults.string(forKey: "insightsProvider"))
            XCTAssertEqual(try storage.read(), APICredentials())
            let reloaded = AppStore(directory: directory, defaults: defaults)
            XCTAssertEqual(reloaded.configuration.provider, .whisperCpp)
            XCTAssertTrue(reloaded.configuration.apiKey.isEmpty)
            XCTAssertTrue(reloaded.configuration.insightsAPIKey.isEmpty)
        }
    }

    @MainActor
    func testSupportedCustomizedServicesAndKeysSurviveReload() throws {
        try withSettings { defaults, directory in
            defaults.set(true, forKey: "localASRMigration")
            defaults.set(TranscriptionProvider.dashScope.rawValue, forKey: "provider")
            defaults.set("https://dashscope-intl.aliyuncs.com/api/v1", forKey: "apiBaseURL")
            defaults.set("custom-asr", forKey: "transcriptionModel")
            defaults.set("OpenAI 兼容 API", forKey: "insightsProvider")
            defaults.set("https://dashscope.aliyuncs.com/compatible-mode/v1", forKey: "insightsBaseURL")
            defaults.set("custom-content-model", forKey: "insightsModel")
            let keys = APICredentials(transcriptionKey: "asr-test-key", insightsKey: "content-test-key")
            try CredentialStorage(directory: directory).save(keys)

            let store = AppStore(directory: directory, defaults: defaults)
            XCTAssertTrue(store.saveSettings())
            let reloaded = AppStore(directory: directory, defaults: defaults)
            XCTAssertEqual(reloaded.configuration.provider, .dashScope)
            XCTAssertEqual(reloaded.configuration.baseURL, "https://dashscope-intl.aliyuncs.com/api/v1")
            XCTAssertEqual(reloaded.configuration.transcriptionModel, "custom-asr")
            XCTAssertEqual(reloaded.configuration.insightsBaseURL, "https://dashscope.aliyuncs.com/compatible-mode/v1")
            XCTAssertEqual(reloaded.configuration.summaryModel, "custom-content-model")
            XCTAssertEqual(reloaded.configuration.apiKey, keys.transcriptionKey)
            XCTAssertEqual(reloaded.configuration.insightsAPIKey, keys.insightsKey)
        }
    }

    @MainActor
    func testOldSharedSummaryConfigurationIsPreservedIndependentlyOfRemovedASR() throws {
        try withSettings { defaults, directory in
            defaults.set(true, forKey: "localASRMigration")
            defaults.set("OpenAI 兼容 API", forKey: "provider")
            defaults.set(true, forKey: "useRemoteInsights")
            defaults.set("https://content.example/v1", forKey: "apiBaseURL")
            defaults.set("custom-summary", forKey: "summaryModel")
            try CredentialStorage(directory: directory).save(APICredentials(transcriptionKey: "old-shared-test-key"))
            let store = AppStore(directory: directory, defaults: defaults)
            XCTAssertEqual(store.configuration.provider, .whisperCpp)
            XCTAssertTrue(store.configuration.apiKey.isEmpty)
            XCTAssertEqual(store.configuration.insightsBaseURL, "https://content.example/v1")
            XCTAssertEqual(store.configuration.summaryModel, "custom-summary")
            XCTAssertEqual(store.configuration.insightsAPIKey, "old-shared-test-key")
        }
    }

    @MainActor
    private func withSettings(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "RustleSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(defaults, directory)
    }
}
