import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var store: AppStore
    let record: Recording
    @State private var plainText = false
    @State private var editingSegment: TranscriptSegment?

    private var segments: [TranscriptSegment] {
        record.segments.filter { store.transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(store.transcriptSearch) || $0.speaker.localizedCaseInsensitiveContains(store.transcriptSearch) }
    }
    var body: some View {
        VStack(spacing: 0) {
            MediaPlayerView(record: record).padding(.horizontal, 28).padding(.bottom, 22)
            HStack(spacing: 12) {
                Text("转写文稿").font(.system(size: 14, weight: .semibold))
                Text("\(record.segments.count) 段").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Spacer()
                Picker("显示方式", selection: $plainText) {
                    Text("逐段").tag(false)
                    Text("全文").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 116)
                IconButton(symbol: "doc.on.doc", label: "复制全部文稿", action: store.copyTranscript).disabled(record.segments.isEmpty)
            }.padding(.horizontal, 29)
            HStack(spacing: 10) {
                NativeSearchField(placeholder: "在文稿中查找", text: $store.transcriptSearch).frame(height: 24)
                if !store.transcriptSearch.isEmpty {
                    Text("\(segments.count) 个匹配").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if record.segments.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: record.status == .processing ? "waveform" : "text.alignleft").font(.system(size: 28, weight: .light))
                                Text(record.status == .processing ? "正在聆听，请稍候" : "文稿将在转写后出现在这里").font(.system(size: 12))
                                if record.status == .processing { Text("可随时查看其他记录").font(.system(size: 10)) }
                            }.foregroundStyle(Palette.secondary).frame(maxWidth: .infinity).padding(.top, 65)
                        } else if segments.isEmpty {
                            Text("没有找到相关内容").font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(25)
                        } else if plainText {
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(segments) { segment in
                                    transcriptText(segment)
                                }
                            }.padding(.horizontal, 29).padding(.vertical, 17)
                        } else {
                            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                                segmentRow(segment, index: index).id(segment.id)
                            }
                        }
                    }.padding(.bottom, 25)
                }
                .onChange(of: record.segments.last?.id) { _, id in
                    if store.liveSession?.id == record.id, store.transcriptSearch.isEmpty, let id {
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .onChange(of: activeSegmentID) { _, id in
                    if store.isPlaying, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: record.isDemo ? "info.circle" : "checkmark.circle")
                Text(record.isDemo ? "示例文稿 · 导入自己的文件即可开始" : record.status == .processing ? "转写结果持续追加 · 完成后可编辑和播放" : "点击时间戳跳转播放 · 双击段落编辑")
                Spacer()
                Text("\(record.transcript.count) 字")
            }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.horizontal, 29).frame(height: 36)
                .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
        .sheet(item: $editingSegment) { segment in
            TranscriptSegmentEditor(segment: segment) { store.editSegment(segment.id, text: $0) }
                .id(segment.id)
        }
    }
    private var activeSegmentID: UUID? {
        guard store.canPlay else { return nil }
        return record.segments.last { $0.start <= store.playhead }?.id
    }
    private func segmentRow(_ segment: TranscriptSegment, index: Int) -> some View {
        let active = activeSegmentID == segment.id
        let speakerColor: Color = speakerIndex(segment.speaker) % 2 == 0 ? Palette.accent : Color.purple
        return HStack(alignment: .top, spacing: 15) {
            Button { store.seek(to: segment.start) } label: {
                Text(segment.start.timestamp).font(.system(size: 11, design: .monospaced)).foregroundStyle(active ? Palette.accent : Palette.secondary).padding(.top, 3)
            }.buttonStyle(.plain).disabled(!store.canPlay).help(store.canPlay ? "跳转至此处" : "示例记录未附带媒体")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(speakerColor.opacity(0.8)).frame(width: 5, height: 5)
                    Text(segment.speaker).font(.system(size: 11, weight: .medium)).foregroundStyle(speakerColor.opacity(0.85))
                    Spacer()
                    Button { beginEditing(segment) } label: { Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(Palette.secondary) }.buttonStyle(.plain).help("编辑此段").disabled(record.status == .processing)
                }
                transcriptText(segment)
            }
        }.padding(.vertical, 17).padding(.horizontal, 17).background(active ? Palette.accent.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12)
    }
    private func transcriptText(_ segment: TranscriptSegment) -> some View {
        EditableTranscriptText(text: segment.text) { beginEditing(segment) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("双击文字编辑此段")
            .accessibilityAction(named: Text("编辑此段")) { beginEditing(segment) }
    }
    private func beginEditing(_ segment: TranscriptSegment) {
        guard editingSegment == nil, record.status != .processing else { return }
        editingSegment = segment
    }
    private func speakerIndex(_ speaker: String) -> Int {
        var speakers: [String] = []
        for segment in record.segments where !speakers.contains(segment.speaker) { speakers.append(segment.speaker) }
        return speakers.firstIndex(of: speaker) ?? 0
    }
}

private struct TranscriptSegmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    let segment: TranscriptSegment
    let onSave: (String) -> Void
    @State private var text: String

    init(segment: TranscriptSegment, onSave: @escaping (String) -> Void) {
        self.segment = segment
        self.onSave = onSave
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑文稿").font(.title3.bold())
            Text("\(segment.speaker) · \(segment.start.timestamp)").font(.caption).foregroundStyle(Palette.secondary)
            TextEditor(text: $text).font(.system(size: 14)).scrollContentBackground(.hidden).padding(10)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 8)).frame(height: 180)
            Text("修改原文后，可重新整理内容洞察以更新摘要和待办。").font(.caption).foregroundStyle(Palette.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button("保存修改") { onSave(text); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(25).frame(width: 520).background(Palette.panel)
    }
}

// Handle double clicks before NSTextView's native word-selection behavior.
private struct EditableTranscriptText: NSViewRepresentable {
    let text: String
    let onEdit: () -> Void

    func makeNSView(context: Context) -> TranscriptTextView {
        let view = TranscriptTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: TranscriptTextView, context: Context) {
        view.onEdit = onEdit
        guard view.string != text else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let bounds = nsView.attributedString().boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: width, height: ceil(bounds.height))
    }
}

private final class TranscriptTextView: NSTextView {
    var onEdit: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            // Present after AppKit finishes dispatching the mouse event.
            DispatchQueue.main.async { [weak self] in self?.onEdit?() }
        } else {
            super.mouseDown(with: event)
        }
    }
}

struct MediaPlayerView: View {
    @EnvironmentObject var store: AppStore
    let record: Recording

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: record.sourceKind.symbol)
                    .font(.system(size: 19)).foregroundStyle(Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.isDemo ? "\(record.sourceKind.label) · 示例内容" : record.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(record.isDemo ? "演示内容，未附带原始媒体" : "\(record.sourceKind.label) · \(record.duration.durationLabel)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: store.cyclePlaybackRate) {
                    Text(String(format: "%g×", store.playbackRate)).monospacedDigit().frame(minWidth: 24)
                }.controlSize(.small).disabled(!store.canPlay).help("调整播放速度")
            }
            HStack(spacing: 12) {
                Button { store.seek(to: store.playhead - 10) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 16))
                }.buttonStyle(.borderless).disabled(!store.canPlay).help("后退 10 秒")
                Button(action: store.togglePlayback) {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15)).frame(width: 22, height: 22)
                }.buttonStyle(.borderless).disabled(!store.canPlay)
                    .help(store.canPlay ? "播放 / 暂停" : "示例未附带媒体")
                    .accessibilityLabel(store.isPlaying ? "暂停" : "播放")
                Text(store.playhead.timestamp).monospacedDigit().foregroundStyle(.secondary)
                Slider(value: Binding(get: { store.playhead }, set: { store.seek(to: $0) }), in: 0...max(1, record.duration))
                    .controlSize(.small).disabled(!store.canPlay)
                    .accessibilityLabel("播放进度").accessibilityValue(store.playhead.timestamp)
                Text(record.duration.timestamp).monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 11))
        }
        .padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line.opacity(0.6)))
    }
}
