import Foundation

struct RuntimeEnvironmentCheck: Identifiable {
    enum Status { case ready, failed, optional, skipped }
    enum Kind: String { case system, storage, whisper, model, downloader }
    var id: Kind
    var title: String
    var status: Status
    var detail: String
    var remedy: String?
    var command: String?
    var blocksTranscription: Bool { status == .failed }
}

struct RuntimeEnvironmentReport {
    var checks: [RuntimeEnvironmentCheck]
    var checkedAt = Date()
    var failures: [RuntimeEnvironmentCheck] { checks.filter(\.blocksTranscription) }
}

/// Local checks only: never downloads software, uploads media, or calls an API.
enum RuntimeEnvironmentChecker {
    static func check(configuration: ProcessingConfiguration, directory: URL,
                      includeOptional: Bool = true,
                      downloader: URL? = ProcessingEngine.findDownloader(),
                      timeout: TimeInterval = 5) async throws -> RuntimeEnvironmentReport {
        var checks = try await Task.detached {
            try Task.checkCancellation()
            let version = ProcessInfo.processInfo.operatingSystemVersion
            var checks = [RuntimeEnvironmentCheck(id: .system, title: "macOS", status: version.majorVersion >= 14 ? .ready : .failed,
                detail: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) · 需要 macOS 14 或更新版本",
                remedy: version.majorVersion >= 14 ? nil : "请在系统设置中更新 macOS。")]
            checks.append(storageCheck(directory))
            if configuration.provider == .whisperCpp {
                checks.append(modelCheck(configuration))
            } else {
                checks.append(.init(id: .model, title: "Whisper 模型", status: .skipped, detail: "当前使用百炼 ASR，无需本地模型。"))
            }
            return checks
        }.value
        try Task.checkCancellation()
        if configuration.provider == .whisperCpp {
            let executable = LocalWhisperService.resolveExecutable(configuration.whisperExecutablePath)
            let check = try await executableCheck(executable, id: .whisper, title: "Whisper 运行程序", arguments: ["--help"],
                remedy: "请在下方选择可运行的 whisper-cli，或重新安装 whisper.cpp。源码运行可执行：./scripts/setup-local-asr.sh base。也可切换至百炼 ASR。",
                command: nil, timeout: timeout)
            checks.insert(check, at: 2)
        } else {
            checks.insert(.init(id: .whisper, title: "Whisper 运行程序", status: .skipped, detail: "当前使用百炼 ASR，无需本地运行程序。"), at: 2)
        }
        if includeOptional {
            checks.append(try await executableCheck(downloader, id: .downloader, title: "视频网站下载 · yt-dlp（可选）", arguments: ["--version"],
                remedy: "如需导入视频网站播放页面，请先安装 Homebrew，再在终端执行下方命令。已安装时可更新或重装 yt-dlp；脚本版还需可用的 Python。安装后重新检测。",
                command: "brew install yt-dlp", timeout: timeout, optional: true))
        }
        try Task.checkCancellation()
        return RuntimeEnvironmentReport(checks: checks)
    }

    private static func storageCheck(_ directory: URL) -> RuntimeEnvironmentCheck {
        let probe = directory.appendingPathComponent(".environment-check-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: probe) }
            try Data("Rustle".utf8).write(to: probe, options: .withoutOverwriting)
            guard try Data(contentsOf: probe) == Data("Rustle".utf8) else { throw CocoaError(.fileReadUnknown) }
            return .init(id: .storage, title: "本地存储", status: .ready, detail: "可读写 · \(directory.path)")
        } catch {
            return .init(id: .storage, title: "本地存储", status: .failed, detail: "无法读写记录目录：\(directory.path)",
                remedy: "请检查此目录的访问权限和磁盘剩余空间，修复后重新打开 Rustle。")
        }
    }

    private static func modelCheck(_ configuration: ProcessingConfiguration) -> RuntimeEnvironmentCheck {
        let remedy = "请在下方选择 whisper.cpp GGML .bin 模型，或点击“管理与下载模型”重新下载。中文需使用多语言模型。"
        guard let model = LocalWhisperService.resolveModel(configuration.whisperModelPath) else {
            return .init(id: .model, title: "Whisper 模型", status: .failed, detail: "尚未选择可用模型，请从下拉列表选择或下载模型。", remedy: remedy)
        }
        do {
            let file = try FileHandle(forReadingFrom: model)
            defer { try? file.close() }
            // whisper.cpp GGML magic (0x67676d6c), followed by eleven Int32 hyperparameters.
            let header = try file.read(upToCount: 48) ?? Data()
            guard header.count == 48, Array(header.prefix(4)) == [0x6c, 0x6d, 0x67, 0x67] else {
                return .init(id: .model, title: "Whisper 模型", status: .failed, detail: "模型头无效或文件不完整：\(model.path)", remedy: remedy)
            }
            let language = try LocalWhisperService.languageCode(configuration.localeIdentifier)
            if model.lastPathComponent.contains(".en."), language != "en", language != "auto" {
                return .init(id: .model, title: "Whisper 模型", status: .failed, detail: "仅英语模型与当前识别语言不匹配。", remedy: remedy + "也可将音频语言改为英语。")
            }
            return .init(id: .model, title: "Whisper 模型", status: .ready, detail: "可读取，模型头有效 · \(model.path)")
        } catch {
            return .init(id: .model, title: "Whisper 模型", status: .failed, detail: "无法读取模型或识别语言无效。", remedy: remedy)
        }
    }

    private static func executableCheck(_ executable: URL?, id: RuntimeEnvironmentCheck.Kind, title: String,
                                        arguments: [String], remedy: String, command: String?, timeout: TimeInterval,
                                        optional: Bool = false) async throws -> RuntimeEnvironmentCheck {
        let failure: RuntimeEnvironmentCheck.Status = optional ? .optional : .failed
        guard let executable else {
            return .init(id: id, title: title, status: failure, detail: optional ? "未安装；本地文件和媒体直链仍可使用。" : "未找到可执行文件。", remedy: remedy, command: command)
        }
        do {
            let output = try await StreamingProcess().run(executable: executable, arguments: arguments, timeout: timeout)
            try Task.checkCancellation()
            let text = output.stdout + output.stderr
            // --help must expose the flags used by local transcription, rather than merely exit successfully.
            let valid = id == .whisper ? ["--model", "--output-json", "--print-progress"].allSatisfy { text.contains($0) }
                : !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard output.status == 0, valid else {
                return .init(id: id, title: title, status: failure, detail: "程序无法正常运行或版本不兼容：\(executable.path)", remedy: remedy, command: command)
            }
            return .init(id: id, title: title, status: .ready, detail: "启动检查通过 · \(executable.path)")
        } catch is CancellationError { throw CancellationError() }
        catch {
            return .init(id: id, title: title, status: failure, detail: "启动失败或检测超时，请检查程序架构及依赖：\(executable.path)", remedy: remedy, command: command)
        }
    }
}
