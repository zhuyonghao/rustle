import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @EnvironmentObject var store: AppStore
    @State private var dropTargeted = false
    @State private var recordToDelete: Recording?
    @State private var showRename = false
    @State private var newTitle = ""
    @State private var showTranscript = true

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(onDelete: { recordToDelete = $0 })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if let record = store.selected {
                    InsightsView(record: record).id(record.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { emptyState }
            }
            .background(Palette.background)
            .navigationTitle(store.selected?.title ?? "Rustle")
            .navigationSubtitle(store.filter.rawValue)
            .inspector(isPresented: $showTranscript) {
                VStack(spacing: 0) {
                    if let record = store.selected {
                        recordingHeader(record)
                        TranscriptView(record: record)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("转写文稿", systemImage: "text.alignleft", description: Text("选择一条记录查看文稿与播放媒体。"))
                    }
                }
                .background(Palette.background)
                .inspectorColumnWidth(min: 380, ideal: 460, max: 640)
            }
            .toolbar { workspaceToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .foregroundStyle(Palette.text)
        .frame(minWidth: 960, minHeight: 640)
        .disabled(store.isMigratingStorage)
        .focusedSceneValue(\.deleteRecordingAction, store.selected == nil ? nil : { requestSelectedDeletion() })
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast).font(.system(size: 12)).padding(.horizontal, 18).padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(Palette.line))
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 5).padding(.bottom, 20)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).fill(Palette.background.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [9])))
                    .overlay(VStack(spacing: 14) { Image(systemName: "arrow.down.doc").font(.system(size: 38)); Text("松开文件，开始转写").font(.title2); Text("支持音频和视频文件").foregroundStyle(Palette.secondary) })
                    .padding(12).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: store.receiveDrop)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Rustle.importFiles"))) { _ in store.chooseFiles() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Rustle.importLink"))) { _ in store.showLinkSheet = true }
        .sheet(isPresented: $store.showLinkSheet) { ImportLinkView() }
        .sheet(isPresented: $store.showSettingsSheet) { AppSettingsView() }
        .alert("需要留意", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("知道了", role: .cancel) { store.alertMessage = nil }
        } message: { Text(store.alertMessage ?? "") }
        .alert("删除记录及其内容？", isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }), presenting: recordToDelete) { record in
            Button("取消", role: .cancel) { recordToDelete = nil }
            Button("删除", role: .destructive) {
                recordToDelete = nil
                Task { await store.deleteRecording(record.id) }
            }
        } message: { record in
            Text("将永久删除「\(record.title)」及其文稿、摘要、思维导图、待办、追问、翻译和本地媒体副本。正在进行的处理也会取消，原始文件不受影响。")
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("记录名称", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("保存") { store.renameSelected(newTitle) }
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: store.chooseFiles) { Label("导入文件", systemImage: "plus") }
                .help("导入音频或视频 · ⌘O")
            Button { store.showLinkSheet = true } label: { Label("导入链接", systemImage: "link") }
                .help("导入媒体链接 · ⌘L")
        }
        ToolbarItemGroup(placement: .automatic) {
            if let record = store.selected {
                Button { store.toggleFavorite(record.id) } label: {
                    Label(record.isFavorite ? "取消收藏" : "收藏记录", systemImage: record.isFavorite ? "star.fill" : "star")
                }
                .tint(record.isFavorite ? Color.orange : nil)
                .help(record.isFavorite ? "取消收藏" : "收藏记录")
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.rawValue) { store.exportSelected(format) }
                    }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .disabled(record.segments.isEmpty).help("导出文稿与笔记")
                Menu {
                    Button("重命名…") { newTitle = record.title; showRename = true }
                    Button("复制全部文字", action: store.copyTranscript).disabled(record.segments.isEmpty)
                } label: { Label("更多操作", systemImage: "ellipsis.circle") }
                    .help("更多操作")
                Button(role: .destructive, action: requestSelectedDeletion) {
                    Label("删除记录及内容", systemImage: "trash")
                }
                .help("删除记录及其全部内容 · ⌘⌫")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button { withAnimation { showTranscript.toggle() } } label: {
                Label(showTranscript ? "隐藏转写文稿" : "显示转写文稿", systemImage: "sidebar.right")
            }
            .help(showTranscript ? "隐藏转写文稿" : "显示转写文稿")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private func requestSelectedDeletion() {
        guard recordToDelete == nil, !showRename, !store.showLinkSheet, !store.showSettingsSheet,
              let record = store.selected else { return }
        recordToDelete = record
    }

    private func recordingHeader(_ record: Recording) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(record.title).font(.system(size: 24, weight: .bold)).lineLimit(2)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Label(record.sourceKind.label, systemImage: record.sourceKind.symbol)
                        Label(record.createdAt.formatted(.dateTime.month().day().hour().minute()), systemImage: "calendar")
                        Label(record.duration.timestamp, systemImage: "clock")
                        Text(record.language)
                        if record.isDemo { CapsuleLabel(text: "示例") }
                    }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
            }
            if record.status == .processing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text(store.processingStage).font(.system(size: 12, weight: .medium))
                        Spacer()
                        if let percent = store.processingProgress?.percentLabel {
                            Text(percent).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent)
                        }
                        Button("取消", action: store.cancelProcessing).buttonStyle(.plain).foregroundStyle(Palette.secondary)
                    }
                    if let fraction = store.processingProgress?.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(store.processingProgress?.detail ?? "正在处理，请稍候")
                        Spacer()
                        if let started = store.processingStartedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text("已用时 \(max(0, context.date.timeIntervalSince(started)).timestamp)").monospacedDigit()
                            }
                        }
                    }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }.padding(14).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            } else if record.status == .failed {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.amber)
                    Text(record.errorMessage ?? "处理失败，请重试。").font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("设置") { store.showSettingsSheet = true }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                }.padding(14).background(Palette.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 22)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("把声音，变成有用的文字", systemImage: "waveform")
        } description: {
            Text("拖入音频或视频，或导入媒体链接，即可开始转写。")
        } actions: {
            HStack(spacing: 12) {
                Button("导入文件", action: store.chooseFiles).buttonStyle(.borderedProminent)
                Button("导入链接") { store.showLinkSheet = true }.buttonStyle(.bordered)
            }
        }
    }
}
