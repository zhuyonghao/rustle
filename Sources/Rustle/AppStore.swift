import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct InsightGenerationKey: Hashable {
    var recordingID: UUID
    var feature: InsightFeature
}

struct InsightGenerationState {
    let token = UUID()
    let startedAt = Date()
    var progress = "正在等待 AI 服务返回"
    var preview = ""
}

@MainActor
final class AppStore: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { loadPlayer() } } }
    @Published var filter: LibraryFilter = .all
    @Published var search = ""
    @Published var transcriptSearch = ""
    @Published var showLinkSheet = false
    @Published var showSettingsSheet = false
    @Published var alertMessage: String?
    @Published var toast: String?
    @Published var processingID: UUID?
    @Published var processingStage = ""
    @Published var processingProgress: ProcessingProgress?
    @Published var processingStartedAt: Date?
    private var progressToken = UUID()
    @Published private(set) var insightGenerations: [InsightGenerationKey: InsightGenerationState] = [:]
    var generatingInsights: Bool { !insightGenerations.isEmpty }

    func insightGeneration(for id: UUID, feature: InsightFeature) -> InsightGenerationState? {
        insightGenerations[InsightGenerationKey(recordingID: id, feature: feature)]
    }
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var playbackRate: Float = 1
    @Published var configuration = ProcessingConfiguration()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var importTask: Task<Void, Never>?
    private var insightTasks: [InsightGenerationKey: Task<Void, Never>] = [:]
    private var terminationObserver: NSObjectProtocol?
    private let engine: ProcessingEngine
    private let defaults: UserDefaults
    private var persistenceAvailable = true
    @Published private(set) var dataDirectory: URL
    @Published private(set) var isMigratingStorage = false
    @Published private(set) var storageMigrationError: String?
    let storageLocationIsOverridden: Bool
    let modelManager: WhisperModelManager

    init(engine: ProcessingEngine = ProcessingEngine(), directory: URL? = nil, initialConfiguration: ProcessingConfiguration? = nil, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        let override = ProcessInfo.processInfo.environment["RUSTLE_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        storageLocationIsOverridden = directory == nil && override != nil
        let savedDirectory = defaults.string(forKey: LibraryStorageMigration.preferenceKey).flatMap { $0.isEmpty ? nil : $0 }
        let initialDirectory = directory ?? override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? savedDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LibraryStorageMigration.defaultDirectory
        dataDirectory = initialDirectory
        modelManager = WhisperModelManager(directory: initialDirectory.appendingPathComponent("Models", isDirectory: true))
        var removedLegacyInsights = false
        var repairedTranscriptTimeline = false
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let libraryURL = dataDirectory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: libraryURL.path) {
                recordings = try JSONDecoder().decode([Recording].self, from: Data(contentsOf: libraryURL))
                for index in recordings.indices {
                    if recordings[index].discardLegacyInsights() { removedLegacyInsights = true }
                    if !recordings[index].isDemo, recordings[index].repairTranscriptTimeline() { repairedTranscriptTimeline = true }
                }
                for index in recordings.indices where recordings[index].status == .processing {
                    recordings[index].status = .failed
                    recordings[index].errorMessage = "上次处理被中断，可重新导入文件。"
                }
            } else { recordings = DemoContent.recordings }
        } catch {
            recordings = DemoContent.recordings
            let original = dataDirectory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: original.path) {
                do {
                    let backup = dataDirectory.appendingPathComponent("library-backup-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: original, to: backup)
                    alertMessage = "记录库读取失败，原文件已备份为 \(backup.lastPathComponent)。当前显示示例内容。"
                } catch {
                    persistenceAvailable = false
                    alertMessage = "记录库无法读取或备份，已暂停保存以保护原文件：\(error.localizedDescription)"
                }
            } else {
                persistenceAvailable = false
                alertMessage = "无法创建本地存储，已暂停保存：\(error.localizedDescription)"
            }
        }
        if let initialConfiguration {
            configuration = initialConfiguration
        } else {
            let savedProvider = defaults.string(forKey: "provider")
            let removedTranscriptionProvider = savedProvider.map { TranscriptionProvider(rawValue: $0) == nil } ?? false
            configuration.provider = TranscriptionProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .whisperCpp
            if !defaults.bool(forKey: "localASRMigration") {
                configuration.provider = .whisperCpp
                defaults.set(true, forKey: "localASRMigration")
                defaults.set(TranscriptionProvider.whisperCpp.rawValue, forKey: "provider")
            }
            configuration.localeIdentifier = defaults.string(forKey: "locale") ?? "zh-CN"
            configuration.whisperExecutablePath = defaults.string(forKey: "whisperExecutablePath") ?? ""
            configuration.whisperModelPath = defaults.string(forKey: "whisperModelPath") ?? ""
            configuration.whisperUseGPU = defaults.object(forKey: "whisperUseGPU") as? Bool ?? true
            if !removedTranscriptionProvider {
                configuration.baseURL = defaults.string(forKey: "apiBaseURL") ?? configuration.baseURL
                configuration.transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? configuration.transcriptionModel
            }
            // Do not access legacy Keychain items: even migration can prompt for a login password.
            let credentials: APICredentials
            do { credentials = try CredentialStorage(directory: dataDirectory).read() }
            catch {
                credentials = APICredentials()
                alertMessage = "本地 API Key 读取失败，请在设置中重新填写并保存。"
            }
            configuration.apiKey = removedTranscriptionProvider ? "" : credentials.transcriptionKey
            let removedInsightsProvider = defaults.string(forKey: "insightsProvider") == "Kimi API"
            configuration.insightsAPIKey = removedInsightsProvider ? "" : credentials.insightsKey
            if !removedInsightsProvider {
                if let address = defaults.string(forKey: "insightsBaseURL") {
                    configuration.insightsBaseURL = address
                    configuration.summaryModel = defaults.string(forKey: "insightsModel") ?? configuration.summaryModel
                } else if defaults.bool(forKey: "useRemoteInsights"), !credentials.transcriptionKey.isEmpty {
                    // Preserve the oldest shared content-service configuration independently of ASR.
                    configuration.insightsBaseURL = defaults.string(forKey: "apiBaseURL") ?? configuration.insightsBaseURL
                    configuration.insightsAPIKey = credentials.transcriptionKey
                    configuration.summaryModel = defaults.string(forKey: "summaryModel") ?? "gpt-4o-mini"
                }
            }
        }
        if initialConfiguration == nil,
           configuration.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let model = modelManager.defaultModelURL() {
            configuration.whisperModelPath = model.path
        }
        if repairedTranscriptTimeline {
            let library = dataDirectory.appendingPathComponent("library.json")
            let backup = dataDirectory.appendingPathComponent("library-before-timeline-repair-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: library, to: backup)
                save()
            } catch {
                persistenceAvailable = false
                alertMessage = "文稿时间顺序已在内存中修复，但原记录备份失败，已暂停保存：\(error.localizedDescription)"
            }
        } else if removedLegacyInsights {
            let library = dataDirectory.appendingPathComponent("library.json")
            let backup = dataDirectory.appendingPathComponent("library-before-api-insights.json")
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: library, to: backup) }
            save()
        }
        selectedID = recordings.first?.id
        loadPlayer()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAllWork() }
        }
    }

    var selected: Recording? { recordings.first { $0.id == selectedID } }
    var visibleRecordings: [Recording] {
        recordings.filter { record in
            (filter != .favorites || record.isFavorite)
            && (search.isEmpty || record.title.localizedCaseInsensitiveContains(search) || record.transcript.localizedCaseInsensitiveContains(search))
        }
    }
    var canPlay: Bool { player != nil }
    var completedTaskCount: Int { selected?.actionItems?.filter(\.isCompleted).count ?? 0 }

    @discardableResult func save() -> Bool {
        guard persistenceAvailable, !isMigratingStorage else { return false }
        do { try JSONEncoder().encode(recordings).write(to: dataDirectory.appendingPathComponent("library.json"), options: .atomic); return true }
        catch { alertMessage = "保存失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult func saveSettings() -> Bool {
        guard !isMigratingStorage else { return false }
        do {
            try CredentialStorage(directory: dataDirectory).save(APICredentials(
                transcriptionKey: configuration.apiKey, insightsKey: configuration.insightsAPIKey
            ))
        } catch {
            alertMessage = "API Key 未能保存到本机，请检查存储目录权限。当前会话仍可使用。"
            return false
        }
        defaults.set(configuration.provider.rawValue, forKey: "provider")
        defaults.set(configuration.localeIdentifier, forKey: "locale")
        defaults.set(configuration.whisperExecutablePath, forKey: "whisperExecutablePath")
        defaults.set(configuration.whisperModelPath, forKey: "whisperModelPath")
        defaults.set(configuration.whisperUseGPU, forKey: "whisperUseGPU")
        defaults.removeObject(forKey: "useRemoteInsights")
        defaults.set(configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "apiBaseURL")
        defaults.set(configuration.transcriptionModel, forKey: "transcriptionModel")
        defaults.removeObject(forKey: "insightsProvider")
        defaults.set(configuration.insightsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "insightsBaseURL")
        defaults.set(configuration.summaryModel, forKey: "insightsModel")
        announce("设置已保存"); return true
    }

    var storageChangeUnavailableReason: String? {
        if storageLocationIsOverridden { return "存储位置由 RUSTLE_DATA_DIR 环境变量指定，请修改环境变量后重新启动。" }
        if isMigratingStorage { return "正在迁移本地数据，请等待完成。" }
        if importTask != nil || generatingInsights || modelManager.isDownloading {
            return "请等待导入、内容生成和模型下载结束后再更改位置。"
        }
        return nil
    }

    func chooseStorageParent() -> URL? {
        storageMigrationError = nil
        if let reason = storageChangeUnavailableReason { storageMigrationError = reason; return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.message = "选择存储位置，将在其中新建 Rustle 文件夹，并复制现有记录、媒体、已下载模型和密钥。原目录保留作为备份。"
        panel.prompt = "迁移到此位置"
        guard panel.runModal() == .OK, let parent = panel.url else { return nil }
        return parent.appendingPathComponent("Rustle", isDirectory: true)
    }

    @discardableResult func changeStorageLocation(to destination: URL) async -> Bool {
        storageMigrationError = nil
        if let reason = storageChangeUnavailableReason { storageMigrationError = reason; return false }
        guard persistenceAvailable, save() else {
            storageMigrationError = "当前记录库无法保存，请修复存储目录后再迁移。"
            return false
        }
        let original = dataDirectory
        var newConfiguration = configuration
        let model = configuration.whisperModelPath.isEmpty ? LocalWhisperService.resolveModel("")?.path ?? "" : configuration.whisperModelPath
        let executable = configuration.whisperExecutablePath.isEmpty ? LocalWhisperService.resolveExecutable("")?.path ?? "" : configuration.whisperExecutablePath
        let newModel = LibraryStorageMigration.relocatedPath(model, from: original, to: destination)
        let newExecutable = LibraryStorageMigration.relocatedPath(executable, from: original, to: destination)
        if newModel != model { newConfiguration.whisperModelPath = newModel }
        if newExecutable != executable { newConfiguration.whisperExecutablePath = newExecutable }
        isMigratingStorage = true
        player?.pause(); isPlaying = false
        defer { isMigratingStorage = false }
        do {
            let migrated = try await LibraryStorageMigration.migrate(from: original, to: destination, recordings: recordings)
            // Publish and persist the new location only after the entire copy succeeds.
            dataDirectory = destination.standardizedFileURL
            recordings = migrated
            configuration = newConfiguration
            modelManager.changeStorageDirectory(to: dataDirectory.appendingPathComponent("Models", isDirectory: true))
            defaults.set(dataDirectory.path, forKey: LibraryStorageMigration.preferenceKey)
            for (key, livePath, relocated, configured) in [
                ("whisperModelPath", model, newModel, configuration.whisperModelPath),
                ("whisperExecutablePath", executable, newExecutable, configuration.whisperExecutablePath)
            ] {
                if relocated != livePath { defaults.set(configured, forKey: key) }
                else if let saved = defaults.string(forKey: key) {
                    defaults.set(LibraryStorageMigration.relocatedPath(saved, from: original, to: dataDirectory), forKey: key)
                }
            }
            loadPlayer()
            announce("存储位置已更改，原目录保留作为备份")
            return true
        } catch {
            storageMigrationError = "迁移未完成，仍使用原位置：\(error.localizedDescription)"
            return false
        }
    }

    func chooseWhisperFile(model: Bool) {
        guard !isMigratingStorage else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = model ? "选择 whisper.cpp 的 ggml 多语言模型（.bin）" : "选择 whisper.cpp 的 whisper-cli 可执行文件"
        panel.prompt = "选择"
        if model { panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data] }
        if panel.runModal() == .OK, let url = panel.url {
            if model { configuration.whisperModelPath = url.path }
            else { configuration.whisperExecutablePath = url.path }
        }
    }

    func useWhisperModel(_ url: URL) {
        guard !isMigratingStorage else { return }
        guard let model = LocalWhisperService.resolveModel(url.path) else { alertMessage = "模型文件不可读取，请重新下载或选择文件。"; return }
        configuration.provider = .whisperCpp
        configuration.whisperModelPath = model.path
        defaults.set(configuration.provider.rawValue, forKey: "provider")
        defaults.set(model.path, forKey: "whisperModelPath")
        announce("已启用 \(model.lastPathComponent)")
    }

    func downloadWhisperModel() {
        guard !isMigratingStorage else { return }
        modelManager.startDownload { [weak self] url in self?.useWhisperModel(url) }
    }

    func chooseFiles() {
        guard !isMigratingStorage else { return }
        guard importTask == nil else { announce("请等待当前导入完成，或先取消处理"); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择音频或视频，Rustle 将提取其中的语音。"
        panel.prompt = "导入并转写"
        if panel.runModal() == .OK { importMedia(panel.urls) }
    }

    func importLink(_ input: String) {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            alertMessage = "请输入完整的 http 或 https 媒体链接。"; return
        }
        showLinkSheet = false
        importMedia([url])
    }

    func importMedia(_ urls: [URL]) {
        guard !isMigratingStorage else { announce("正在迁移本地数据，请稍后再导入"); return }
        guard importTask == nil else { announce("已有文件正在处理，请稍后再导入"); return }
        guard persistenceAvailable else { alertMessage = "本地存储不可用，请修复目录权限后重新打开 Rustle。"; return }
        let config = configuration
        importTask = Task {
            defer { progressToken = UUID(); processingID = nil; processingStage = ""; processingProgress = nil; processingStartedAt = nil; importTask = nil }
            do {
                let report = try await RuntimeEnvironmentChecker.check(configuration: config, directory: dataDirectory, includeOptional: false)
                guard report.failures.isEmpty else {
                    showSettingsSheet = true
                    announce("运行环境未就绪：" + report.failures.map(\.title).joined(separator: "、") + "。请在设置中查看修复方法。")
                    return
                }
            } catch { return }
            for url in urls {
                if Task.isCancelled { break }
                let kind: SourceKind = !url.isFileURL ? .link : (["mp4", "mov", "m4v", "webm", "mkv"].contains(url.pathExtension.lowercased()) ? .video : .audio)
                let title = url.isFileURL ? url.deletingPathExtension().lastPathComponent : "正在获取视频标题…"
                let record = Recording(title: title.isEmpty ? "新导入的媒体" : title, duration: 0, sourceKind: kind, sourceURL: url.absoluteString, status: .processing, segments: [])
                recordings.insert(record, at: 0)
                selectedID = record.id
                processingID = record.id
                processingStartedAt = Date()
                processingProgress = nil
                filter = .all; search = ""
                save()
                do {
                    processingStage = url.isFileURL ? "正在读取媒体…" : "正在下载媒体…"
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let directory = dataDirectory.appendingPathComponent("Media/\(record.id.uuidString)", isDirectory: true)
                    let media = try await engine.prepareMedia(from: url, destinationDirectory: directory, progress: progressHandler(for: record.id))
                    try Task.checkCancellation()
                    update(record.id) { $0.localMediaPath = media.url.path; $0.title = media.title }
                    save()
                    processingProgress = nil
                    processingStage = "正在读取音轨…"
                    let result = try await engine.transcribe(url: media.url, configuration: config, progress: progressHandler(for: record.id))
                    try Task.checkCancellation()
                    update(record.id) {
                        $0.segments = result.segments; $0.duration = result.duration; $0.language = result.language
                        $0.status = .ready; $0.errorMessage = nil
                    }
                    progressToken = UUID(); processingProgress = nil
                    if selectedID == record.id { loadPlayer() }
                    announce("转写已完成，正在生成摘要与思维导图")
                    queueAutomaticInsights(for: record.id)
                } catch {
                    update(record.id) {
                        $0.status = .failed
                        if $0.title == "正在获取视频标题…" { $0.title = "链接导入失败" }
                        $0.errorMessage = Task.isCancelled ? "处理已取消。可重新导入此文件。" : error.localizedDescription
                    }
                }
                save()
            }
        }
    }

    private func progressHandler(for id: UUID) -> @Sendable (ProcessingProgress) -> Void {
        let token = UUID(); progressToken = token
        return { [weak self] update in
            Task { @MainActor in
                guard let self, self.processingID == id, self.progressToken == token else { return }
                self.processingProgress = update
                self.processingStage = update.title
            }
        }
    }

    func cancelProcessing() {
        progressToken = UUID(); processingProgress = nil
        importTask?.cancel(); processingStage = "正在取消…"
    }

    private func stopAllWork() {
        importTask?.cancel()
        for task in insightTasks.values { task.cancel() }
        insightTasks.removeAll(); insightGenerations.removeAll()
        modelManager.cancel()
        player?.pause()
    }

    private func queueAutomaticInsights(for id: UUID) {
        for feature in [InsightFeature.overview, .mindMap] {
            guard let record = recordings.first(where: { $0.id == id }), record.status == .ready,
                  !record.hasInsight(feature) else { continue }
            generateInsight(feature, for: id)
        }
    }

    func generateInsight(_ feature: InsightFeature, question: String = "", language: SubtitleLanguage = .english) {
        guard let id = selectedID else { return }
        generateInsight(feature, for: id, question: question, language: language)
    }

    private func generateInsight(_ feature: InsightFeature, for id: UUID, question: String = "", language: SubtitleLanguage = .english) {
        guard !isMigratingStorage else { return }
        guard let record = recordings.first(where: { $0.id == id }), !record.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.status != .processing else { return }
        let key = InsightGenerationKey(recordingID: id, feature: feature)
        guard insightTasks[key] == nil else { return }
        let state = InsightGenerationState()
        insightGenerations[key] = state
        let stream: @Sendable (String) -> Void = { [weak self] content in
            let preview = ChatCompletionStream.preview(content)
            Task { @MainActor in
                guard let self, self.insightGenerations[key]?.token == state.token else { return }
                self.insightGenerations[key]?.preview = preview
            }
        }
        let progress: @Sendable (String) -> Void = { [weak self] detail in
            Task { @MainActor in
                guard let self, self.insightGenerations[key]?.token == state.token else { return }
                self.insightGenerations[key]?.progress = detail
            }
        }
        update(record.id) {
            if $0.contentInsights == nil { $0.contentInsights = ContentInsights() }
            $0.contentInsights?.errors?[feature.rawValue] = nil
            $0.insightsError = nil
        }
        let config = configuration
        insightTasks[key] = Task {
            defer {
                if insightGenerations[key]?.token == state.token {
                    insightGenerations[key] = nil; insightTasks[key] = nil
                }
            }
            do {
                var result = ContentInsights()
                switch feature {
                case .overview: result.overview = try await engine.generateOverview(transcript: record.transcript, configuration: config, stream: stream)
                case .mindMap: result.mindMap = try await engine.generateMindMap(transcript: record.transcript, configuration: config, stream: stream, progress: progress)
                case .tasks: result.tasks = try await engine.generateActionItems(transcript: record.transcript, configuration: config, stream: stream)
                case .followUp:
                    result.answers = [try await engine.answerQuestion(question, transcript: record.transcript, history: record.contentInsights?.answers ?? [], configuration: config, stream: stream)]
                case .translation:
                    result.translation = try await engine.translateSubtitles(segments: record.segments, language: language, configuration: config, stream: stream, progress: progress)
                }
                try Task.checkCancellation()
                guard insightGenerations[key]?.token == state.token else { return }
                guard recordings.first(where: { $0.id == record.id })?.segments == record.segments else {
                    announce("文稿已变更，请重新生成内容洞察"); return
                }
                update(record.id) {
                    if $0.contentInsights == nil { $0.contentInsights = ContentInsights() }
                    switch feature {
                    case .overview: $0.contentInsights?.overview = result.overview
                    case .mindMap: $0.contentInsights?.mindMap = result.mindMap
                    case .tasks: $0.contentInsights?.tasks = result.tasks
                    case .followUp:
                        let answers = ($0.contentInsights?.answers ?? []) + (result.answers ?? [])
                        $0.contentInsights?.answers = answers
                    case .translation: $0.contentInsights?.translation = result.translation
                    }
                }
                save(); announce("\(feature.title)已生成")
            } catch {
                if Task.isCancelled { return }
                guard insightGenerations[key]?.token == state.token else { return }
                guard recordings.first(where: { $0.id == record.id })?.segments == record.segments else { return }
                update(record.id) {
                    if $0.contentInsights?.errors == nil { $0.contentInsights?.errors = [:] }
                    $0.contentInsights?.errors?[feature.rawValue] = error.localizedDescription
                }
                save()
            }
        }
    }

    func cancelInsightGeneration(_ feature: InsightFeature? = nil, for recordingID: UUID? = nil) {
        guard let id = recordingID ?? selectedID else { return }
        let keys = insightTasks.keys.filter { $0.recordingID == id && (feature == nil || $0.feature == feature) }
        for key in keys {
            insightTasks.removeValue(forKey: key)?.cancel()
            insightGenerations[key] = nil
        }
    }

    func toggleFavorite(_ id: UUID) { guard !isMigratingStorage else { return }; update(id) { $0.isFavorite.toggle() }; save() }
    func toggleTask(_ taskID: UUID) {
        guard !isMigratingStorage else { return }
        guard let id = selectedID else { return }
        update(id) { record in
            if let index = record.contentInsights?.tasks?.firstIndex(where: { $0.id == taskID }) {
                record.contentInsights?.tasks?[index].isCompleted.toggle()
            } else if let index = record.insights?.tasks.firstIndex(where: { $0.id == taskID }) {
                record.insights?.tasks[index].isCompleted.toggle()
            }
        }
        save()
    }
    func editSegment(_ id: UUID, text: String) {
        guard !isMigratingStorage else { return }
        guard let recordID = selectedID else { return }
        guard let record = selected, let segment = record.segments.first(where: { $0.id == id }), segment.text != text else { return }
        cancelInsightGeneration(for: recordID)
        update(recordID) { record in
            if let index = record.segments.firstIndex(where: { $0.id == id }), record.segments[index].text != text {
                record.segments[index].text = text
                record.insights = nil; record.contentInsights = nil; record.insightsError = nil
            }
        }
        save()
    }
    func renameSelected(_ title: String) {
        guard !isMigratingStorage else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = selectedID, !value.isEmpty else { return }
        update(id) { $0.title = value }; save()
    }
    func deleteRecording(_ id: UUID) async {
        guard !isMigratingStorage else { return }
        guard recordings.contains(where: { $0.id == id }) else { return }
        guard persistenceAvailable else {
            alertMessage = "本地存储不可用，无法删除记录。请修复目录权限后重新打开 Rustle。"
            return
        }
        let previous = recordings
        recordings.removeAll { $0.id == id }
        guard save() else { recordings = previous; return }
        if selectedID == id { selectedID = visibleRecordings.first?.id }
        cancelInsightGeneration(for: id)
        if processingID == id {
            let task = importTask
            cancelProcessing()
            // Wait for media writers to stop before removing their directory.
            await task?.value
        }
        let mediaDirectory = dataDirectory.appendingPathComponent("Media/\(id.uuidString)")
        do {
            if FileManager.default.fileExists(atPath: mediaDirectory.path) {
                try FileManager.default.removeItem(at: mediaDirectory)
            }
            announce("记录及其内容已删除")
        } catch {
            alertMessage = "记录及文字内容已删除，但本地媒体副本清理失败：\(error.localizedDescription)\n副本位置：\(mediaDirectory.path)"
        }
    }
    func copyTranscript() {
        guard let record = selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.transcript, forType: .string)
        announce("文字已复制")
    }
    func exportSelected(_ format: ExportFormat) {
        guard let record = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.title.replacingOccurrences(of: "/", with: "-") + "." + format.fileExtension
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try TranscriptExporter.export(record, format: format).write(to: url, atomically: true, encoding: .utf8); announce("已导出 \(format.rawValue)") }
            catch { alertMessage = "导出失败：\(error.localizedDescription)" }
        }
    }
    func exportTranslatedSubtitles() {
        guard var record = selected, let translation = record.contentInsights?.translation else { return }
        record.segments = translation.segments
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.title.replacingOccurrences(of: "/", with: "-") + "-" + translation.language.rawValue + ".srt"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url {
            do { try TranscriptExporter.export(record, format: .srt).write(to: url, atomically: true, encoding: .utf8); announce("已导出翻译字幕") }
            catch { alertMessage = "导出失败：\(error.localizedDescription)" }
        }
    }
    func exportMindMap(_ record: Recording) {
        guard let map = record.contentInsights?.mindMap else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.title.replacingOccurrences(of: "/", with: "-") + "-思维导图.png"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.message = "导出完整思维导图，包含所有分支。"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try MindMapImageExporter.pngData(map: map, title: record.title).write(to: url, options: .atomic)
                announce("思维导图图片已导出")
            } catch { alertMessage = "导出失败：\(error.localizedDescription)" }
        }
    }
    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in matching {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else { continuation.resume(returning: value as? URL) }
                    }
                }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { importMedia(urls) }
        }
        return true
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else {
            if playhead >= (selected?.duration ?? 0) - 0.1 { seek(to: 0) }
            player.playImmediately(atRate: playbackRate); isPlaying = true
        }
    }
    func seek(to seconds: Double) {
        guard let player else { return }
        playhead = max(0, min(seconds, selected?.duration ?? 0))
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600))
    }
    func cyclePlaybackRate() {
        let rates: [Float] = [1, 1.25, 1.5, 2, 0.75]
        playbackRate = rates[((rates.firstIndex(of: playbackRate) ?? 0) + 1) % rates.count]
        if isPlaying { player?.rate = playbackRate }
    }
    private func loadPlayer() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil; player?.pause(); player = nil; playhead = 0; isPlaying = false
        transcriptSearch = ""
        guard let path = selected?.localMediaPath, FileManager.default.fileExists(atPath: path) else { return }
        let avPlayer = AVPlayer(url: URL(fileURLWithPath: path))
        player = avPlayer
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.playhead = time.seconds.isFinite ? time.seconds : 0
                if avPlayer.rate == 0 { self.isPlaying = false }
            }
        }
    }
    private func update(_ id: UUID, _ change: (inout Recording) -> Void) {
        if let index = recordings.firstIndex(where: { $0.id == id }) { change(&recordings[index]) }
    }
    func announce(_ text: String) {
        toast = text
        Task { try? await Task.sleep(for: .seconds(4)); if toast == text { toast = nil } }
    }
}

