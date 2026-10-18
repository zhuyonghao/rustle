import Foundation
import SwiftUI

struct InstalledWhisperModel: Identifiable {
    var url: URL
    var title: String
    var location: String
    var id: String { url.path }
}

@MainActor
final class WhisperModelManager: ObservableObject {
    @Published var selectedModelID = "large-v3"
    @Published var source: WhisperDownloadSource
    @Published var customAddress: String
    @Published var fallbackEnabled: Bool
    @Published private(set) var isDownloading = false
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var status = "选择模型和下载源，校验通过后即可使用。"
    @Published private(set) var errorMessage: String?
    @Published private(set) var completedURL: URL?
    @Published private(set) var isVerifying = false
    @Published private(set) var directory: URL
    private var operation: Task<Void, Never>?
    private let downloader: WhisperModelDownloader
    private var activeAttemptID: UUID?

    init(directory: URL, downloader: WhisperModelDownloader = WhisperModelDownloader()) {
        self.directory = directory
        self.downloader = downloader
        let defaults = UserDefaults.standard
        source = WhisperDownloadSource(rawValue: defaults.string(forKey: "modelDownloadSource") ?? "") ?? .huggingFace
        customAddress = defaults.string(forKey: "modelDownloadCustomAddress") ?? ""
        fallbackEnabled = defaults.object(forKey: "modelDownloadFallback") as? Bool ?? true
    }

    var selectedModel: WhisperModelDefinition { WhisperModelDefinition.catalog.first { $0.id == selectedModelID } ?? WhisperModelDefinition.catalog.last! }
    var progress: Double? { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : nil }
    var progressLabel: String {
        let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
        return totalBytes > 0 ? "\(received) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))" : received
    }

    func availableURL(for model: WhisperModelDefinition) -> URL? {
        var candidates = [directory.appendingPathComponent(model.filename)]
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Models").appendingPathComponent(model.filename)) }
        if let detected = LocalWhisperService.resolveModel(""), detected.lastPathComponent == model.filename { candidates.append(detected) }
        return candidates.first { LocalWhisperService.resolveModel($0.path) != nil }
    }

    func installedModels(configuredPath: String) -> [InstalledWhisperModel] {
        let files = FileManager.default
        var folders: [(URL, String)] = [(directory, "已下载")]
        if let resources = Bundle.main.resourceURL {
            folders.append((resources.appendingPathComponent("Models", isDirectory: true), "应用内置"))
            folders.append((resources.appendingPathComponent("Whisper/models", isDirectory: true), "应用内置"))
        }
        folders.append((URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent(".runtime/models", isDirectory: true), "本地运行环境"))
        folders += ["/opt/homebrew/share/whisper-cpp/models", "/usr/local/share/whisper-cpp/models"].map { (URL(fileURLWithPath: $0, isDirectory: true), "系统安装") }
        var candidates: [(URL, String)] = []
        if let model = LocalWhisperService.resolveModel(configuredPath) {
            candidates.append((model, configuredPath.isEmpty ? "环境变量指定" : "当前选择"))
            if !configuredPath.isEmpty { folders.append((model.deletingLastPathComponent(), "自选目录")) }
        }
        for (folder, location) in folders {
            let urls = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            candidates += urls.filter { $0.pathExtension.lowercased() == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { ($0, location) }
        }
        var seen = Set<String>()
        return candidates.compactMap { url, location in
            guard let model = LocalWhisperService.resolveModel(url.path), seen.insert(model.resolvingSymlinksInPath().path).inserted else { return nil }
            let definition = WhisperModelDefinition.catalog.first { $0.filename == model.lastPathComponent }
            return InstalledWhisperModel(url: model, title: definition?.title ?? model.deletingPathExtension().lastPathComponent, location: location)
        }
    }

    /// Explicit environment configuration takes precedence over the built-in quality order.
    func defaultModelURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["RUSTLE_WHISPER_MODEL"], !path.isEmpty {
            return LocalWhisperService.resolveModel("")
        }
        let installed = installedModels(configuredPath: "")
        // The catalog runs from lightweight models to the full Large v3 model.
        for definition in WhisperModelDefinition.catalog.reversed() {
            if let model = installed.first(where: { $0.url.lastPathComponent == definition.filename }) {
                return model.url
            }
        }
        return nil
    }

    func startDownload(onComplete: @escaping (URL) -> Void) {
        guard operation == nil else { return }
        let model = selectedModel
        let selectedSource = source
        let address = customAddress
        do { _ = try selectedSource.url(for: model, customAddress: address) }
        catch { errorMessage = error.localizedDescription; status = "请检查自定义下载地址后重试。"; return }
        let defaults = UserDefaults.standard
        defaults.set(selectedSource.rawValue, forKey: "modelDownloadSource")
        defaults.set(address, forKey: "modelDownloadCustomAddress")
        defaults.set(fallbackEnabled, forKey: "modelDownloadFallback")
        isDownloading = true; isVerifying = false; receivedBytes = 0; totalBytes = 0; completedURL = nil; errorMessage = nil
        let sources = selectedSource.fallbackSources(enabled: fallbackEnabled)
        operation = Task {
            defer { isDownloading = false; isVerifying = false; activeAttemptID = nil; operation = nil }
            for (index, candidate) in sources.enumerated() {
                do {
                    try Task.checkCancellation()
                    receivedBytes = 0; totalBytes = 0; isVerifying = false
                    let attemptID = UUID()
                    activeAttemptID = attemptID
                    status = "\(index > 0 ? "原下载源失败，正在切换至 " : "正在连接 ")\(candidate.title)…"
                    let url = try candidate.url(for: model, customAddress: address)
                    let installed = try await downloader.download(model, from: url, directory: directory) { [weak self] update in
                        Task { @MainActor in
                            guard let self, self.isDownloading, self.activeAttemptID == attemptID else { return }
                            switch update {
                            case .downloading(let received, let total):
                                if !self.isVerifying { self.receivedBytes = received; self.totalBytes = total; self.status = "正在下载 \(model.title) · \(candidate.title)" }
                            case .verifying: self.isVerifying = true; self.status = "正在校验模型完整性…"
                            }
                        }
                    }
                    completedURL = installed
                    status = "\(model.title) 下载完成，校验通过。"
                    onComplete(installed)
                    return
                } catch {
                    if Task.isCancelled || error is CancellationError { status = "下载已取消，当前使用的模型未改变。"; return }
                    if index == sources.count - 1 { errorMessage = error.localizedDescription; status = "下载未完成，可切换下载源后重试。" }
                }
            }
        }
    }

    func cancel() { operation?.cancel() }

    func changeStorageDirectory(to directory: URL) {
        guard !isDownloading else { return }
        self.directory = directory
        completedURL = nil
    }
}
