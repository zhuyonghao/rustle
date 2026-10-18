import SwiftUI

struct ModelDownloadView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: WhisperModelManager

    private var installedURL: URL? { manager.availableURL(for: manager.selectedModel) }
    private var activeModelName: String? { LocalWhisperService.resolveModel(store.configuration.whisperModelPath)?.lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle").font(.system(size: 26, weight: .light)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("下载本地 Whisper 模型").font(.system(size: 20, weight: .semibold))
                    Text("选择适合的模型与下载源，下载完成后即可离线识别。")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                IconButton(symbol: "xmark", label: "关闭模型下载窗口") { dismiss() }
            }.padding(25)
            Form {
                Section("选择模型") {
                    Picker("多语言模型", selection: $manager.selectedModelID) {
                        ForEach(WhisperModelDefinition.catalog) { model in Text("\(model.title) · \(model.sizeLabel)").tag(model.id) }
                    }.disabled(manager.isDownloading)
                    Text("较大的模型通常需要更多内存和识别时间。所有列表模型均支持多语言，量化模型可以减少存储与内存占用。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    if let installedURL {
                        HStack {
                            Label(activeModelName == installedURL.lastPathComponent ? "当前正在使用" : "本机已有此模型", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Palette.accent)
                            Spacer()
                            Button("使用此模型") { store.useWhisperModel(installedURL) }.disabled(manager.isDownloading)
                        }.font(.system(size: 12))
                    }
                }
                Section("下载源") {
                    Picker("来源", selection: $manager.source) {
                        ForEach(WhisperDownloadSource.allCases) { source in Text(source.title).tag(source) }
                    }.disabled(manager.isDownloading)
                    if manager.source == .custom {
                        TextField("下载地址", text: $manager.customAddress, prompt: Text("https://example.com/models/{filename}"))
                            .disabled(manager.isDownloading)
                        Text("填写模型直链、目录地址，或使用 {filename} 模板。例如 ggml-small.bin 将替换 {filename}。自定义源同样需要通过官方校验值验证。")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    } else {
                        Toggle("连接失败时自动切换另一下载源", isOn: $manager.fallbackEnabled).disabled(manager.isDownloading)
                        Text(manager.source == .hfMirror ? "HF Mirror 是第三方镜像，下载速度与可用性取决于网络和镜像状态。" : "从 whisper.cpp 维护者的 Hugging Face 模型仓库下载。")
                            .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                    }
                }
                Section("下载状态") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(manager.status).font(.system(size: 12)).foregroundStyle(Palette.text)
                        if manager.isDownloading {
                            if manager.isVerifying { ProgressView().controlSize(.small) }
                            else {
                                if let progress = manager.progress { ProgressView(value: progress) }
                                else { ProgressView().progressViewStyle(.linear) }
                                HStack {
                                    Text(manager.progressLabel)
                                    Spacer()
                                    if let progress = manager.progress { Text("\(Int(progress * 100))%") }
                                }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                            }
                        }
                        if let error = manager.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Palette.amber).textSelection(.enabled)
                        }
                    }.padding(.vertical, 3)
                }
                Section {
                    Text("模型保存位置：\(manager.directory.path)。可在设置中更改本地存储位置。更换下载源只影响模型文件的获取，音视频仍在本地转写。关闭此窗口后下载会继续；退出应用会取消下载。")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(4)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            HStack {
                Text(manager.selectedModel.filename).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                Spacer()
                if manager.isDownloading {
                    Button("取消下载", action: manager.cancel).buttonStyle(.bordered)
                } else {
                    Button(installedURL == nil ? "下载并使用" : "重新下载并使用", action: store.downloadWhisperModel)
                        .buttonStyle(.borderedProminent).disabled(manager.source == .custom && manager.customAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(.horizontal, 25).padding(.bottom, 23)
        }.frame(width: 625, height: 685).background(Palette.panel).foregroundStyle(Palette.text).tint(Palette.accent)
            .disabled(store.isMigratingStorage)
    }
}
