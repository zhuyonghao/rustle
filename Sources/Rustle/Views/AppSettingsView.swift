import SwiftUI
import AppKit

struct AppSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var selectedPage: SettingsPage = .transcription
    @State private var showModelDownloads = false
    @State private var environmentReport: RuntimeEnvironmentReport?
    @State private var showEnvironmentDetails = false
    @State private var checkRevision = 0
    private struct CheckInput: Hashable {
        var provider: String
        var executable: String
        var model: String
        var locale: String
        var directory: String
        var migrating: Bool
        var revision: Int
    }
    private var checkInput: CheckInput {
        .init(provider: store.configuration.provider.rawValue, executable: store.configuration.whisperExecutablePath,
              model: store.configuration.whisperModelPath, locale: store.configuration.localeIdentifier,
              directory: store.dataDirectory.path, migrating: store.isMigratingStorage, revision: checkRevision)
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                pageHeader
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch selectedPage {
                        case .transcription: transcriptionSettings
                        case .insights: insightsSettings
                        case .storage: LocalStorageSettingsView(manager: store.modelManager)
                        case .environment: environmentSection
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(Palette.text.opacity(0.025))
                .id(selectedPage)
                Divider()
                footer
            }
        }
        .frame(width: 820, height: 660)
        .background(Palette.panel)
        .foregroundStyle(Palette.text)
        .tint(Palette.accent)
        .onExitCommand { if !store.isMigratingStorage { dismiss() } }
        .disabled(store.isMigratingStorage)
        .interactiveDismissDisabled(store.isMigratingStorage)
        .overlay {
            if store.isMigratingStorage {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在迁移本地数据…").font(.headline)
                    Text("完成后自动切换，原目录保留作为备份。请勿退出应用。")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: checkInput) {
            environmentReport = nil
            guard !store.isMigratingStorage else { return }
            do {
                let report = try await RuntimeEnvironmentChecker.check(configuration: store.configuration, directory: store.dataDirectory)
                try Task.checkCancellation()
                environmentReport = report
                if !report.failures.isEmpty { showEnvironmentDetails = true }
            } catch { /* Closing settings or changing a checked field cancels the old result. */ }
        }
        .onChange(of: store.configuration.provider) { _, provider in
            saved = false
            if provider == .dashScope {
                store.configuration.apiKey = ""
                store.configuration.baseURL = DashScopeASR.defaultBaseURL
                store.configuration.transcriptionModel = DashScopeASR.defaultModel
            }
        }
        .onChange(of: configurationValues) { _, _ in saved = false }
        .sheet(isPresented: $showModelDownloads) { ModelDownloadView(manager: store.modelManager).environmentObject(store) }
    }

    private var configurationValues: [String] {
        let configuration = store.configuration
        return [configuration.provider.rawValue, configuration.localeIdentifier,
                configuration.whisperExecutablePath, configuration.whisperModelPath,
                String(configuration.whisperUseGPU), configuration.apiKey, configuration.baseURL,
                configuration.transcriptionModel, configuration.insightsBaseURL,
                configuration.insightsAPIKey, configuration.summaryModel]
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rustle").font(.system(size: 17, weight: .semibold))
                    Text("偏好设置").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 25).padding(.bottom, 30)

            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.secondary)
                .padding(.horizontal, 22).padding(.bottom, 9)
            VStack(spacing: 5) {
                ForEach(SettingsPage.allCases) { page in
                    Button { selectedPage = page } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.symbol).font(.system(size: 14))
                                .frame(width: 19)
                            Text(page.rawValue).font(.system(size: 13, weight: selectedPage == page ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selectedPage == page ? Palette.accent : Palette.text)
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .background(selectedPage == page ? Palette.accent.opacity(0.1) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedPage == page ? [.isSelected] : [])
                }
            }.padding(.horizontal, 10)
            Spacer()
            Button { selectedPage = .environment } label: {
                HStack(spacing: 7) {
                    if let report = environmentReport {
                        Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(report.failures.isEmpty ? Color.green : Palette.amber)
                        Text(report.failures.isEmpty ? "运行环境已就绪" : "运行环境需修复")
                    } else {
                        ProgressView().controlSize(.mini)
                        Text("正在检测环境…")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Palette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).help("查看运行环境检测详情")
            .padding(12)
        }
        .frame(width: 176)
    }

    private var pageHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedPage.rawValue).font(.system(size: 22, weight: .semibold))
                Text(selectedPage.subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if saved {
                Label("设置已保存", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            } else {
                Text("保存后，下次启动沿用此配置").foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 8)
            Button("保存设置") { saved = store.saveSettings() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24).padding(.vertical, 15)
    }

    private var transcriptionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "识别偏好", symbol: "waveform") {
                SettingsRow("识别服务") {
                    Picker("识别服务", selection: $store.configuration.provider) {
                        ForEach(TranscriptionProvider.allCases) { provider in Text(provider.rawValue).tag(provider) }
                    }.labelsHidden().frame(width: 250)
                }
                Divider()
                SettingsRow("音频语言") {
                    Picker("音频语言", selection: $store.configuration.localeIdentifier) {
                        Text("自动检测").tag("auto")
                        Text("普通话 · 简体中文").tag("zh-CN")
                        Text("English · 英语").tag("en-US")
                        Text("日本語 · 日语").tag("ja-JP")
                        Text("粤语 · 繁体中文").tag("zh-HK")
                        Text("한국어 · 韩语").tag("ko-KR")
                    }.labelsHidden().frame(width: 250)
                }
                SettingsNote(text: providerDescription, symbol: store.configuration.provider == .whisperCpp ? "lock.shield" : "cloud")
            }
            if store.configuration.provider == .whisperCpp {
                SettingsCard(title: "本地模型", symbol: "cpu") {
                    localFileRow(title: "运行程序", path: LocalWhisperService.resolveExecutable(store.configuration.whisperExecutablePath)?.path, model: false)
                    Divider()
                    LocalWhisperModelPicker(manager: store.modelManager)
                    Divider()
                    SettingsRow("GPU 加速") {
                        Toggle("使用 GPU 加速", isOn: $store.configuration.whisperUseGPU)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    SettingsNote(text: "使用 whisper.cpp 的 ggml .bin 模型。中文请选择多语言模型，避免 .en 模型；关闭 GPU 后使用 CPU 转写。", symbol: "info.circle")
                    Button { showModelDownloads = true } label: {
                        Label("管理与下载模型…", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }.controlSize(.large)
                }
            } else {
                transcriptionAPISettings
            }
        }
    }

    private var transcriptionAPISettings: some View {
        SettingsCard(title: "语音转写 API", symbol: "cloud") {
            SettingsField("API 地址", text: $store.configuration.baseURL, prompt: "https://dashscope.aliyuncs.com/api/v1")
            SettingsField("API Key", text: $store.configuration.apiKey, prompt: "填写转写服务密钥", secure: true)
            SettingsField("识别模型", text: $store.configuration.transcriptionModel, prompt: "模型名称")
            if store.configuration.provider == .dashScope {
                Button("使用内容整理中的百炼密钥") {
                    store.configuration.apiKey = store.configuration.insightsAPIKey
                    saved = false
                }.disabled(!canReuseDashScopeKey)
                SettingsNote(text: "音轨将发送至百炼识别。长音频自动按 3 分钟分段，返回的时间戳用于字幕与跳转。", symbol: "info.circle")
            }
            SettingsNote(text: "此处仅用于语音识别，与内容整理服务分别配置。", symbol: "slider.horizontal.3")
        }
    }

    private var insightsSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "内容整理 API", symbol: "sparkles") {
                SettingsRow("整理服务") {
                    Text("OpenAI 兼容 API").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Divider()
                SettingsField("API 地址", text: $store.configuration.insightsBaseURL, prompt: "https://api.openai.com/v1")
                SettingsField("API Key", text: $store.configuration.insightsAPIKey, prompt: "填写内容整理服务密钥", secure: true)
                SettingsField("洞察模型", text: $store.configuration.summaryModel, prompt: "模型名称")
            }
            SettingsCard(title: "生成与隐私", symbol: "lock.shield") {
                SettingsNote(text: "转写完成后自动生成摘要与思维导图。待办、追问和 SRT 翻译在点击后生成；调用失败可单独重试。", symbol: "sparkles")
                Divider()
                SettingsNote(text: "文稿会发送到以上 API 服务，音视频由语音转写服务处理。API 调用可能产生服务商费用。", symbol: "arrow.up.doc")
                Divider()
                SettingsNote(text: "密钥以明文保存在本机，通过文件权限限制其他账户访问。首次从旧版升级需重新填写密钥。", symbol: "key")
            }
        }
    }

    private var environmentSection: some View {
        SettingsCard(title: "运行环境检测", symbol: "checkmark.shield") {
            HStack {
                if let report = environmentReport {
                    Label(report.failures.isEmpty ? "转写运行环境已就绪" : "运行环境需要修复",
                          systemImage: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(report.failures.isEmpty ? Color.green : Palette.amber)
                } else {
                    ProgressView().controlSize(.small)
                    Text("正在检测运行环境…")
                }
                Spacer()
                Button("重新检测") { checkRevision += 1 }.disabled(environmentReport == nil)
            }
            if let report = environmentReport {
                if report.checks.contains(where: { $0.status == .optional }) {
                    Text("可选的 yt-dlp 未就绪，视频网站播放页面导入可能不可用。")
                        .font(.system(size: 11)).foregroundStyle(Palette.amber)
                }
                DisclosureGroup("查看检测详情", isExpanded: $showEnvironmentDetails) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(report.checks) { check in
                            VStack(alignment: .leading, spacing: 7) {
                                Label(check.title + " · " + statusTitle(check.status), systemImage: statusSymbol(check.status))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(statusColor(check.status))
                                Text(check.detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let remedy = check.remedy {
                                    Text(remedy).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let command = check.command {
                                    HStack {
                                        Text(command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        Spacer()
                                        Button("复制安装命令") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(command, forType: .string)
                                        }.controlSize(.small)
                                    }
                                }
                                if check.status == .failed && (check.id == .whisper || check.id == .model) {
                                    HStack {
                                        Button(check.id == .model ? "选择模型…" : "选择运行程序…") {
                                            store.chooseWhisperFile(model: check.id == .model)
                                        }
                                        if check.id == .model {
                                            Button("管理与下载模型…") { showModelDownloads = true }
                                        }
                                    }.controlSize(.small)
                                }
                            }.padding(.vertical, 4)
                        }
                        Text("检测于 \(report.checkedAt.formatted(date: .omitted, time: .standard))。仅在本机检查程序启动、模型头和目录读写；模型完整性、GPU 实际推理、网络、API 密钥及额度以实际处理结果为准。")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("本地文件和媒体直链无需 yt-dlp、Python 或 FFmpeg。百炼 ASR 需另行配置 API。")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        }
    }

    private func statusTitle(_ status: RuntimeEnvironmentCheck.Status) -> String {
        switch status { case .ready: "通过"; case .failed: "需修复"; case .optional: "可选项未就绪"; case .skipped: "无需配置" }
    }
    private func statusSymbol(_ status: RuntimeEnvironmentCheck.Status) -> String {
        switch status { case .ready: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .optional: "info.circle"; case .skipped: "minus.circle" }
    }
    private func statusColor(_ status: RuntimeEnvironmentCheck.Status) -> Color {
        switch status { case .ready: Color.green; case .failed, .optional: Palette.amber; case .skipped: Palette.secondary }
    }

    private var providerDescription: String {
        switch store.configuration.provider {
        case .whisperCpp: "使用开源 Whisper 模型在本机识别，不上传音视频，不需要语音识别权限。"
        case .dashScope: "使用阿里云百炼 Qwen Audio ASR 识别音频，支持中文及多语种。音轨会上传，服务商可能按用量计费。"
        }
    }

    private var canReuseDashScopeKey: Bool {
        func isDashScope(_ address: String) -> Bool {
            guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  components.scheme == "https", let host = components.host?.lowercased(),
                  components.user == nil, components.password == nil else { return false }
            return ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com"].contains(host) || host.hasSuffix(".maas.aliyuncs.com")
        }
        return !store.configuration.insightsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isDashScope(store.configuration.insightsBaseURL) && isDashScope(store.configuration.baseURL)
    }

    private func localFileRow(title: String, path: String?, model: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13))
                Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未找到，点击选择文件")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(path == nil ? Palette.amber : Palette.secondary)
                    .lineLimit(1).truncationMode(.middle).help(path ?? "运行 scripts/setup-local-asr.sh 下载运行程序与模型")
            }
            Spacer()
            Button("选择…") { store.chooseWhisperFile(model: model) }.controlSize(.small)
            Button("自动") {
                if model { store.configuration.whisperModelPath = "" }
                else { store.configuration.whisperExecutablePath = "" }
            }.controlSize(.small).help("恢复自动检测")
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case transcription = "语音转写"
    case insights = "内容整理"
    case storage = "本地存储"
    case environment = "运行环境"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .transcription: "waveform"
        case .insights: "sparkles"
        case .storage: "externaldrive"
        case .environment: "checkmark.shield"
        }
    }
    var subtitle: String {
        switch self {
        case .transcription: "配置识别服务、语言与本地模型。"
        case .insights: "连接 API，将文稿整理为清晰的笔记。"
        case .storage: "管理资料库位置，让文件井然有序。"
        case .environment: "检查本机依赖与转写所需的运行条件。"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(title).font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: symbol).foregroundStyle(Palette.accent).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 10) { content }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line.opacity(0.35), lineWidth: 0.5))
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title).font(.system(size: 13)).fixedSize()
            Spacer(minLength: 0)
            content
        }.frame(minHeight: 26)
    }
}

private struct SettingsField: View {
    let title: String
    @Binding var text: String
    var prompt: String
    var secure = false

    init(_ title: String, text: Binding<String>, prompt: String, secure: Bool = false) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.secure = secure
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(.system(size: 12)).frame(width: 65, alignment: .leading)
            Group {
                if secure { SecureField(title, text: $text, prompt: Text(prompt)) }
                else { TextField(title, text: $text, prompt: Text(prompt)) }
            }
            .textFieldStyle(.roundedBorder).controlSize(.large)
            .font(.system(size: 12)).accessibilityLabel(title)
        }
    }
}

private struct SettingsNote: View {
    var text: String
    var symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).frame(width: 15).padding(.top, 2)
            Text(text).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
        }
        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LocalStorageSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var manager: WhisperModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "资料库位置", symbol: "externaldrive") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder.fill").font(.system(size: 28)).foregroundStyle(Palette.accent.opacity(0.75))
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Rustle 资料库").font(.system(size: 13, weight: .medium))
                        Text(store.dataDirectory.path).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 4)
                Divider()
                HStack {
                    Button("更改位置…") {
                        if let destination = store.chooseStorageParent() {
                            Task { await store.changeStorageLocation(to: destination) }
                        }
                    }.disabled(store.storageChangeUnavailableReason != nil || manager.isDownloading)
                    Spacer()
                    Button { NSWorkspace.shared.open(store.dataDirectory) } label: {
                        Label("在 Finder 中打开", systemImage: "arrow.up.forward.square")
                    }
                }
                if let error = store.storageMigrationError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
                }
                if let reason = store.storageChangeUnavailableReason {
                    SettingsNote(text: reason, symbol: "info.circle")
                }
            }
            SettingsCard(title: "数据与迁移", symbol: "folder.badge.gearshape") {
                SettingsNote(text: "记录、媒体、已下载模型与 API 密钥统一保存在资料库中。", symbol: "tray.full")
                Divider()
                SettingsNote(text: "更改位置会在所选目录新建 Rustle 文件夹，复制数据后立即切换。原目录保留作为备份。", symbol: "arrow.right.arrow.left")
                Divider()
                SettingsNote(text: "删除记录只移除资料库中的副本，不会删除导入前的原文件。", symbol: "doc.on.doc")
            }
        }
    }
}

private struct LocalWhisperModelPicker: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var manager: WhisperModelManager
    @State private var revision = 0

    private var selection: Binding<String> {
        Binding(get: {
            let path = store.configuration.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? LocalWhisperService.resolveModel("")?.path ?? ""
                : URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        }, set: { store.configuration.whisperModelPath = $0 })
    }

    var body: some View {
        let _ = revision
        let models = manager.installedModels(configuredPath: store.configuration.whisperModelPath)
        VStack(alignment: .leading, spacing: 10) {
            SettingsRow("识别模型") {
                Picker("识别模型", selection: selection) {
                    if selection.wrappedValue.isEmpty {
                        Text("请选择模型").tag("").disabled(true)
                    }
                    ForEach(models) { model in
                        Text("\(model.title) · \(model.location)").tag(model.url.path)
                    }
                    if !selection.wrappedValue.isEmpty, !models.contains(where: { $0.url.path == selection.wrappedValue }) {
                        Text("当前模型不可用 · \(URL(fileURLWithPath: selection.wrappedValue).lastPathComponent)").tag(selection.wrappedValue)
                    }
                }.labelsHidden().frame(width: 310)
            }
            HStack {
                Button("选择其他模型文件…") { store.chooseWhisperFile(model: true) }
                Button("刷新列表") { revision += 1 }
                Spacer()
                Text("\(models.count) 个本地模型").font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }.controlSize(.small)
            if let model = LocalWhisperService.resolveModel(store.configuration.whisperModelPath) {
                Text(model.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(model.path)
            }
        }
    }
}

struct ImportLinkView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "link").font(.system(size: 22)).foregroundStyle(Palette.accent)
                Spacer()
                IconButton(symbol: "xmark", label: "关闭") { dismiss() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("导入媒体链接").font(.system(size: 22, weight: .semibold))
                Text("粘贴视频或音频的下载链接，交给 Rustle 整理。").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            TextField("https://example.com/audio.mp3", text: $link).textFieldStyle(.roundedBorder)
                .controlSize(.large).focused($focused)
                .accessibilityLabel("媒体链接")
                .onSubmit { if isValid && store.processingID == nil { store.importLink(link) } }
            VStack(alignment: .leading, spacing: 8) {
                Label("支持直接下载的音视频链接，最大 500 MB", systemImage: "checkmark.circle")
                Text("普通视频网站的播放页面需要本机安装 yt-dlp，并取决于平台支持情况。需要登录或受保护的内容，请使用原始文件。").lineSpacing(5)
            }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
            HStack {
                Button("选择本地文件…") { dismiss(); store.chooseFiles() }.buttonStyle(.bordered)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始转写") { store.importLink(link) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!isValid || store.processingID != nil)
            }.padding(.top, 5)
        }.padding(28).frame(width: 525).background(Palette.panel).foregroundStyle(Palette.text)
            .onAppear { focused = true }
    }
    private var isValid: Bool {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
}
