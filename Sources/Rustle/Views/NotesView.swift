import SwiftUI

struct RecordingContentView: View {
    let record: Recording
    @State private var showingNotes: Bool
    @State private var hasOpenedNotes: Bool

    init(record: Recording) {
        self.record = record
        _showingNotes = State(initialValue: record.sourceKind == .legacyNote)
        _hasOpenedNotes = State(initialValue: record.sourceKind == .legacyNote)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("记录内容", selection: $showingNotes) {
                Label("内容洞察", systemImage: "sparkles").tag(false)
                Label("我的笔记", systemImage: "note.text").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            // Keep the editor mounted when switching tabs so undo and selection survive.
            ZStack {
                InsightsView(record: record)
                    .opacity(showingNotes ? 0 : 1).allowsHitTesting(!showingNotes).accessibilityHidden(showingNotes)
                if hasOpenedNotes {
                    NotesView(record: record)
                        .opacity(showingNotes ? 1 : 0).allowsHitTesting(showingNotes).accessibilityHidden(!showingNotes)
                }
            }
        }
        .onChange(of: showingNotes) { _, value in if value { hasOpenedNotes = true } }
    }
}

struct NotesView: View {
    @EnvironmentObject var store: AppStore
    let record: Recording
    @StateObject private var editor = MarkdownEditorController()
    @State private var editorVersion = UUID()
    @State private var exporting = false

    // Environment updates can render before the parent refreshes its Recording
    // value. Read the live source to avoid echoing stale content into WebKit.
    private var currentMarkdown: String { store.recordings.first(where: { $0.id == record.id })?.noteText ?? record.noteText }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("我的笔记", systemImage: "note.text").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    Task { await exportMarkdown() }
                } label: { Label("导出 Markdown", systemImage: "square.and.arrow.up") }
                    .controlSize(.small).disabled(!editor.isReady || exporting || currentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 24).frame(height: 52)
            if let error = editor.errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label("编辑器暂不可用", systemImage: "exclamationmark.circle").foregroundStyle(Palette.amber)
                    Text(error).foregroundStyle(Palette.secondary)
                    Button("重新加载") { editor.reset(); editorVersion = UUID() }
                }.font(.system(size: 12)).padding(16)
            }
            MarkdownEditorView(markdown: currentMarkdown, onChange: { store.updateNotes(for: record.id, markdown: $0) }, controller: editor)
                .id(editorVersion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if !editor.isReady, editor.errorMessage == nil { ProgressView("正在打开 Markdown 编辑器…").font(.caption) }
                }
            Divider()
            HStack(spacing: 6) {
                if store.unsavedNoteIDs.contains(record.id) {
                    Label("尚未保存", systemImage: "clock")
                    Button("立即保存") { store.save() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                } else { Label("已自动保存到本机", systemImage: "checkmark.circle") }
                Spacer()
                Text("Markdown · \(currentMarkdown.count) 字符")
            }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.horizontal, 24).frame(height: 36)
        }.background(Palette.panel)
    }

    private func exportMarkdown() async {
        exporting = true
        defer { exporting = false }
        do {
            // Read the current DOM before opening the save panel, including the latest keystroke.
            let markdown = try await editor.markdown()
            store.updateNotes(for: record.id, markdown: markdown)
            store.save()
            store.exportNotesMarkdown(for: record.id)
        } catch { store.alertMessage = error.localizedDescription }
    }
}
