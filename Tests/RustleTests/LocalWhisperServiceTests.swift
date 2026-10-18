import Foundation
import XCTest
@testable import Rustle

final class LocalWhisperServiceTests: XCTestCase {
    func testModelMustBeExplicitlySelectedOrProvidedByEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("ggml-base.bin")
        try Data([1, 2, 3]).write(to: model)
        XCTAssertNil(LocalWhisperService.resolveModel("", environment: [:]))
        XCTAssertNil(LocalWhisperService.resolveModel("  ", environment: [:]))
        XCTAssertEqual(LocalWhisperService.resolveModel(model.path, environment: [:]), model)
        let environment = ["RUSTLE_WHISPER_MODEL": model.path]
        XCTAssertEqual(LocalWhisperService.resolveModel("", environment: environment), model)
        XCTAssertNil(LocalWhisperService.resolveModel(directory.appendingPathComponent("missing.bin").path, environment: environment))
    }

    func testChineseLocaleNormalizesScriptWithoutChangingOtherLocales() {
        XCTAssertEqual(LocalWhisperService.normalizedText("產品設計與用戶反饋", localeIdentifier: "zh-CN"), "产品设计与用户反馈")
        XCTAssertEqual(LocalWhisperService.normalizedText("產品設計", localeIdentifier: "zh-HK"), "產品設計")
        XCTAssertEqual(LocalWhisperService.normalizedText("Product design", localeIdentifier: "en-US"), "Product design")
    }
    func testMillisecondOffsetsBecomeGlobalSeconds() throws {
        let data = Data(#"{"result":{"language":"zh"},"transcription":[{"offsets":{"from":500,"to":2250},"text":" 你好，世界。 ","speaker":"不可信身份"}]}"#.utf8)
        let result = try LocalWhisperService.parseOutput(data, offset: 600, duration: 10)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].start, 600.5)
        XCTAssertEqual(result.segments[0].duration, 1.75)
        XCTAssertEqual(result.segments[0].text, "你好，世界。")
        XCTAssertEqual(result.segments[0].speaker, "发言人")
        XCTAssertEqual(result.language, "zh")
    }

    func testInvalidLocalJSONAndTimestampsAreRejected() throws {
        for text in ["not json", "{}", #"{"transcription":[{"offsets":{"from":-1,"to":200},"text":"错误"}]}"#, #"{"transcription":[{"offsets":{"from":3000,"to":2000},"text":"错误"}]}"#] {
            XCTAssertThrowsError(try LocalWhisperService.parseOutput(Data(text.utf8), offset: 0, duration: 10))
        }
        let empty = try LocalWhisperService.parseOutput(Data(#"{"result":{"language":"zh"},"transcription":[]}"#.utf8), offset: 0, duration: 10)
        XCTAssertTrue(empty.segments.isEmpty)
    }

    func testArgumentsUseSeparatePathsAndHonorCPUSetting() {
        let arguments = LocalWhisperService.arguments(model: URL(fileURLWithPath: "/tmp/模型 with spaces.bin"), wave: URL(fileURLWithPath: "/tmp/audio; echo injected.wav"), outputPrefix: URL(fileURLWithPath: "/tmp/output prefix"), language: "zh", useGPU: false)
        XCTAssertEqual(arguments, ["-m", "/tmp/模型 with spaces.bin", "-f", "/tmp/audio; echo injected.wav", "-l", "zh", "-oj", "-pp", "-of", "/tmp/output prefix", "-ng"])
        XCTAssertFalse(LocalWhisperService.arguments(model: URL(fileURLWithPath: "/m"), wave: URL(fileURLWithPath: "/w"), outputPrefix: URL(fileURLWithPath: "/o"), language: "en", useGPU: true).contains("-ng"))
    }

    func testLanguageMappingAndValidation() throws {
        XCTAssertEqual(try LocalWhisperService.languageCode("zh-CN"), "zh")
        XCTAssertEqual(try LocalWhisperService.languageCode("en_US"), "en")
        XCTAssertEqual(try LocalWhisperService.languageCode("ja-JP"), "ja")
        XCTAssertEqual(try LocalWhisperService.languageCode("auto"), "auto")
        XCTAssertThrowsError(try LocalWhisperService.languageCode("中文"))
        XCTAssertThrowsError(try LocalWhisperService.languageCode("zh;rm"))
    }

    func testExplicitInvalidPathsDoNotSilentlyFallback() throws {
        XCTAssertNil(LocalWhisperService.resolveExecutable("/definitely/not/installed/whisper-cli"))
        XCTAssertNil(LocalWhisperService.resolveModel("/definitely/not/installed/ggml-base.bin"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("test.bin")
        try Data([1, 2, 3]).write(to: model)
        XCTAssertEqual(LocalWhisperService.resolveModel(model.path), model)
        XCTAssertNil(LocalWhisperService.resolveExecutable(model.path))
        XCTAssertNil(LocalWhisperService.resolveModel(directory.path))
    }

    func testMissingExecutableReturnsClearLocalErrorBeforeMediaRead() async {
        var config = ProcessingConfiguration()
        config.whisperExecutablePath = "/definitely/not/installed/whisper-cli"
        do {
            _ = try await LocalWhisperService().transcribe(url: URL(fileURLWithPath: "/tmp/nonexistent-audio.wav"), configuration: config)
            XCTFail("Expected missing local executable error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("whisper.cpp"))
            XCTAssertFalse(error.localizedDescription.contains("API Key"))
        }
    }

    func testCancellingLocalRecognitionTerminatesSubprocess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("whisper-cli")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = directory.appendingPathComponent("model.bin")
        try Data([1]).write(to: model)
        let media = directory.appendingPathComponent("sample.wav")
        try Self.stereoWave().write(to: media)
        var config = ProcessingConfiguration()
        config.whisperExecutablePath = executable.path
        config.whisperModelPath = model.path
        let task = Task { try await LocalWhisperService().transcribe(url: media, configuration: config) }
        try await Task.sleep(for: .milliseconds(500))
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected local ASR cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testAVFoundationProduces16kMonoPCM16WAV() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("stereo-32k.wav")
        try Self.stereoWave().write(to: source)
        let output = directory.appendingPathComponent("mono-16k.wav")
        try await LocalWhisperService.exportWAV(from: source, start: 0, duration: 0.4, destination: output)
        let bytes = try Data(contentsOf: output)
        func word(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8) }
        func long(_ offset: Int) -> UInt32 { UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24) }
        XCTAssertEqual(String(data: bytes.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(word(20), 1)
        XCTAssertEqual(word(22), 1)
        XCTAssertEqual(long(24), 16000)
        XCTAssertEqual(word(34), 16)
        XCTAssertEqual(Int(long(40)), bytes.count - 44)
        XCTAssertGreaterThan(bytes.count, 10000)
        XCTAssertLessThan(bytes.count, 15000)
    }

    private static func stereoWave() -> Data {
        var data = Data()
        func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func long(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        let frames = 12800
        data.append(Data("RIFF".utf8)); long(UInt32(36 + frames * 4)); data.append(Data("WAVEfmt ".utf8)); long(16)
        word(1); word(2); long(32000); long(128000); word(4); word(16); data.append(Data("data".utf8)); long(UInt32(frames * 4))
        for index in 0..<frames { let sample = UInt16(bitPattern: Int16(sin(Double(index) * 2 * .pi * 440 / 32000) * 1200)); word(sample); word(sample) }
        return data
    }
}
