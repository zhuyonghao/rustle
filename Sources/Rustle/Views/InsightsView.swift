import SwiftUI

struct InsightsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let record: Recording
    @State private var feature: InsightFeature = .overview
    @State private var question = ""
    @State private var language: SubtitleLanguage = .english

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Palette.accent)
                Text("内容洞察").font(.system(size: 14, weight: .semibold))
                Spacer()
                if isGeneratingFeature {
                    ProgressView().controlSize(.small)
                    IconButton(symbol: "xmark", label: "取消生成") { store.cancelInsightGeneration(feature, for: record.id) }
                } else if record.hasInsight(feature), feature != .followUp {
                    IconButton(symbol: "arrow.clockwise", label: "重新生成\(feature.title)") { generate() }.disabled(!canGenerate)
                }
            }.padding(.horizontal, 20).frame(height: 52)
            Picker("内容", selection: $feature) {
                ForEach(InsightFeature.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.menu).padding(.horizontal, 20).padding(.vertical, 16)
            .onChange(of: feature) { _, item in select(item) }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        SectionCaption(title: feature.title, symbol: feature.symbol)
                        Spacer()
                        if record.hasInsight(feature) { CapsuleLabel(text: record.isDemo && record.contentInsights == nil ? "示例" : "AI 生成", color: Palette.accent) }
                    }
                    if let error = record.contentInsights?.errors?[feature.rawValue] {
                        errorNotice(error)
                    }
                    if isGeneratingFeature {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在生成\(feature.title)…")
                            }
                            Text(generation?.preview.isEmpty == false ? "正在接收生成内容" : generation?.progress ?? "")
                            if generation?.preview.isEmpty == false, let progress = generation?.progress, progress != "正在等待 AI 服务返回" {
                                Text(progress)
                            }
                            if let startedAt = generation?.startedAt {
                                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                    Text("已用时 \(max(0, context.date.timeIntervalSince(startedAt)).timestamp) · 单次请求最多等待 3 分钟，可取消")
                                }
                            }
                        }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        if let preview = generation?.preview, !preview.isEmpty {
                            Text(preview).font(.system(size: 13)).lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    if !isGeneratingFeature || record.hasInsight(feature) || feature == .followUp || feature == .translation {
                        featureContent
                    }
                }.padding(.horizontal, 24).padding(.vertical, 23)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text("转写完成后自动生成摘要与思维导图。待办、追问和翻译按需生成，结果请结合原文核对。")
            }.font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(4).padding(.horizontal, 24).padding(.vertical, 15)
        }.frame(maxHeight: .infinity).background(Palette.panel)
    }

    private var generation: InsightGenerationState? { store.insightGeneration(for: record.id, feature: feature) }
    private var isGeneratingFeature: Bool { generation != nil }
    private var canGenerate: Bool { !record.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && record.status != .processing && !isGeneratingFeature }

    private func select(_ item: InsightFeature) {
        feature = item
        if !record.hasInsight(item), [.overview, .mindMap, .tasks].contains(item), canGenerate { generate() }
    }

    private func generate() { store.generateInsight(feature, question: question, language: language) }

    @ViewBuilder private var featureContent: some View {
        switch feature {
        case .overview:
            if let overview = record.overview { overviewSection(overview) }
            else { emptyState("从长文中提炼摘要与关键要点。") }
        case .mindMap:
            if let map = record.contentInsights?.mindMap {
                HStack(spacing: 12) {
                    Button { openWindow(value: record.id) } label: { Label("放大查看", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Button { store.exportMindMap(record) } label: { Label("导出图片", systemImage: "square.and.arrow.up") }
                }.buttonStyle(.bordered).font(.system(size: 12))
                MindMapOutlineView(map: map)
            } else { emptyState("按主题梳理层级与关联，展开分支查看细节。") }
        case .tasks:
            if let tasks = record.actionItems { tasksSection(tasks) }
            else { emptyState("提取文稿中明确约定的行动、负责人和截止日期。") }
        case .followUp: followUpSection
        case .translation: translationSection
        }
    }

    private func emptyState(_ description: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: feature.symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Palette.accent.opacity(0.6))
            Text(record.status == .processing ? "等待转写完成" : isGeneratingFeature ? "正在生成\(feature.title)" : "生成\(feature.title)").font(.system(size: 13, weight: .medium))
            Text(description).font(.system(size: 12)).lineSpacing(5).multilineTextAlignment(.center).foregroundStyle(Palette.secondary)
            if !isGeneratingFeature {
                Button("生成\(feature.title)") { generate() }.buttonStyle(.borderedProminent).disabled(!canGenerate)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 35)
    }

    private func errorNotice(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(feature.title)未生成成功", systemImage: "exclamationmark.circle").foregroundStyle(Palette.amber)
            Text(error).foregroundStyle(Palette.secondary).lineSpacing(5).textSelection(.enabled)
            HStack {
                Button("重试") { generate() }.disabled(!canGenerate || (feature == .followUp && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Button("服务设置") { store.showSettingsSheet = true }
            }.buttonStyle(.bordered)
        }.font(.system(size: 12)).padding(12).background(Palette.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func overviewSection(_ overview: ContentOverview) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 13) {
                SectionCaption(title: "一眼看懂", symbol: "text.alignleft")
                Text(overview.summary).font(.system(size: 13)).lineSpacing(7).foregroundStyle(Palette.text.opacity(0.8)).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 14) {
                SectionCaption(title: "关键要点", symbol: "lightbulb")
                ForEach(Array(overview.keyPoints.enumerated()), id: \.offset) { index, point in
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(format: "%02d", index + 1)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Palette.accent.opacity(0.8)).padding(.top, 2)
                        Text(point).font(.system(size: 12)).lineSpacing(6).foregroundStyle(Palette.text.opacity(0.76)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("围绕原文继续提问，回答会参考文稿与最近的对话。").font(.system(size: 12)).lineSpacing(5).foregroundStyle(Palette.secondary)
            ForEach(record.contentInsights?.answers ?? []) { item in
                VStack(alignment: .leading, spacing: 12) {
                    Label(item.question, systemImage: "bubble.left").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
                    Text(item.answer).font(.system(size: 12)).lineSpacing(6).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.raised.opacity(0.43), in: RoundedRectangle(cornerRadius: 8))
            }
            TextField("例如：这次讨论做出了哪些决定？", text: $question, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.plain).font(.system(size: 13)).padding(12)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("追问内容")
            Button(isGeneratingFeature ? "正在回答…" : "发送追问") { generate() }.buttonStyle(.borderedProminent)
                .disabled(!canGenerate || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 2000)
            if question.count > 2000 { Text("问题不能超过 2000 字。").font(.system(size: 11)).foregroundStyle(Palette.amber) }
        }.onChange(of: record.contentInsights?.answers?.count) { old, new in
            if (new ?? 0) > (old ?? 0) { question = "" }
        }
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("逐条翻译字幕，保留原始时间轴。选择语言后点击生成。").font(.system(size: 12)).lineSpacing(5).foregroundStyle(Palette.secondary)
            Picker("目标语言", selection: $language) {
                ForEach(SubtitleLanguage.allCases) { language in Text(language.rawValue).tag(language) }
            }.font(.system(size: 12)).disabled(isGeneratingFeature)
            Button(isGeneratingFeature ? "正在翻译…" : "生成\(language.rawValue)字幕") { generate() }.buttonStyle(.borderedProminent).disabled(!canGenerate)
            if let translation = record.contentInsights?.translation {
                HStack {
                    CapsuleLabel(text: translation.language.rawValue, color: Palette.accent)
                    Spacer()
                    Button { store.exportTranslatedSubtitles() } label: { Label("导出 SRT", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                }
                ForEach(translation.segments) { segment in
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(segment.start.timestamp) → \((segment.start + segment.duration).timestamp)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
                        Text(segment.text).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.raised.opacity(0.43), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func tasksSection(_ tasks: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionCaption(title: "把想法，付诸行动", symbol: "checklist")
                Spacer()
                Text("\(tasks.filter(\.isCompleted).count)/\(tasks.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary)
            }
            if tasks.isEmpty {
                Text("这份内容中没有提取到明确待办。").font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.vertical, 8)
            } else {
                ForEach(tasks) { task in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("完成：\(task.title)", isOn: Binding(
                            get: { task.isCompleted },
                            set: { _ in store.toggleTask(task.id) }
                        ))
                        .toggleStyle(.checkbox).labelsHidden().padding(.top, 1)
                        .accessibilityLabel(task.isCompleted ? "取消完成：\(task.title)" : "完成：\(task.title)")
                        VStack(alignment: .leading, spacing: 9) {
                            Text(task.title).font(.system(size: 12)).lineSpacing(5).strikethrough(task.isCompleted)
                                .foregroundStyle(task.isCompleted ? Palette.secondary.opacity(0.6) : Palette.text)
                            HStack(spacing: 6) {
                                Image(systemName: "person.crop.circle").font(.system(size: 11))
                                Text(task.owner)
                                if task.dueDate != "未设截止日期" { Text("·"); Text(task.dueDate).foregroundStyle(task.isCompleted ? Palette.secondary : Palette.amber) }
                            }.font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(12).background(Palette.raised.opacity(0.43), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

