import AppKit
import SwiftUI

struct MindMapView: View {
    @EnvironmentObject var store: AppStore
    let record: Recording
    let map: MindMapNode
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var fitsWindow = true
    @State private var viewport: CGSize = .zero
    private var layout: MindMapLayout { MindMapLayout(map: map) }

    var body: some View {
        let diagram = layout
        VStack(spacing: 0) {
            toolbar(diagram: diagram)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    MindMapDiagram(title: record.title, layout: diagram)
                        .scaleEffect(zoom, anchor: .topLeading)
                        .frame(width: diagram.size.width * zoom, height: diagram.size.height * zoom, alignment: .topLeading)
                        .background(Palette.background)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line.opacity(0.5)) }
                        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
                        .padding(32)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .defaultScrollAnchor(.center)
                .background(Palette.panel)
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if pinchStart == nil { pinchStart = zoom }
                    fitsWindow = false
                    zoom = max(0.1, min(3, (pinchStart ?? zoom) * value.magnification))
                }.onEnded { _ in pinchStart = nil })
                .onAppear { viewport = geometry.size; fit(diagram) }
                .onChange(of: geometry.size) { _, size in
                    viewport = size
                    if fitsWindow { fit(diagram) }
                }
                .onChange(of: map) { _, _ in
                    if fitsWindow { fit(diagram) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "hand.draw")
                Text("双向滚动查看 · 双指捏合缩放")
                Spacer()
                Text("⌘+ / ⌘− 缩放 · ⌘0 原始大小")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).frame(height: 32)
        }
        .frame(minWidth: 800, minHeight: 480)
        .navigationTitle("\(record.title) · 思维导图")
        .alert("导出失败", isPresented: Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })) {
            Button("好") { store.alertMessage = nil }
        } message: { Text(store.alertMessage ?? "") }
    }

    private func toolbar(diagram: MindMapLayout) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: InsightFeature.mindMap.symbol)
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("思维导图").font(.system(size: 13, weight: .semibold))
                    Text("\(map.children.count) 个分支 · \(diagram.nodes.count) 个节点")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button { setZoom(zoom - 0.1) } label: { Image(systemName: "minus").frame(width: 26, height: 28) }
                    .help("缩小 · ⌘−").accessibilityLabel("缩小导图")
                    .keyboardShortcut("-", modifiers: .command).disabled(zoom <= 0.1)
                Slider(value: Binding(get: { zoom }, set: { setZoom($0) }), in: 0.1...3)
                    .frame(width: 90).accessibilityLabel("导图缩放比例")
                Button { setZoom(zoom + 0.1) } label: { Image(systemName: "plus").frame(width: 26, height: 28) }
                    .help("放大 · ⌘+").accessibilityLabel("放大导图")
                    .keyboardShortcut("+", modifiers: .command).disabled(zoom >= 3)
                Button { setZoom(1) } label: {
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.system(size: 11, design: .monospaced)).monospacedDigit().frame(width: 44, height: 28)
                }.help("原始大小 · ⌘0").accessibilityLabel("原始大小，当前缩放 \(Int((zoom * 100).rounded()))%")
                    .keyboardShortcut("0", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8))
            Button { fitsWindow = true; fit(diagram) } label: {
                Label("适应窗口", systemImage: "arrow.up.left.and.arrow.down.right")
            }.buttonStyle(.bordered).tint(fitsWindow ? Palette.accent : nil)
            Divider().frame(height: 24)
            Button { store.exportMindMap(record) } label: { Label("导出图片", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).help("导出包含全部分支的高清 PNG 图片")
        }
        .controlSize(.small).padding(.horizontal, 20).frame(height: 64)
    }

    private func setZoom(_ value: CGFloat) {
        fitsWindow = false
        zoom = max(0.1, min(3, value))
    }

    private func fit(_ diagram: MindMapLayout) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        zoom = max(0.1, min(1, (viewport.width - 64) / diagram.size.width, (viewport.height - 64) / diagram.size.height))
    }
}

/// A readable, collapsible companion to the full-size canvas in the inspector.
struct MindMapOutlineView: View {
    let map: MindMapNode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsed: Set<String> = []

    private var expandablePaths: Set<String> {
        func paths(_ node: MindMapNode, at path: String) -> Set<String> {
            guard !node.children.isEmpty else { return [] }
            return node.children.enumerated().reduce(into: Set([path])) { result, child in
                result.formUnion(paths(child.element, at: "\(path).\(child.offset)"))
            }
        }
        return map.children.enumerated().reduce(into: Set<String>()) { result, child in
            result.formUnion(paths(child.element, at: "\(child.offset)"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("中心主题", systemImage: "circle.hexagongrid.fill")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent)
                Text(map.title).font(.system(size: 15, weight: .semibold)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text("\(map.children.count) 个分支 · \(map.nodeCount) 个节点")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent.opacity(0.16)) }

            if !map.children.isEmpty {
                HStack(spacing: 8) {
                    Text("主题分支").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("全部展开") { collapsed.removeAll() }.disabled(collapsed.isEmpty)
                    Button("全部收起") { collapsed = expandablePaths }.disabled(collapsed == expandablePaths)
                }.font(.system(size: 11)).buttonStyle(.borderless)

                VStack(spacing: 10) {
                    ForEach(Array(map.children.enumerated()), id: \.offset) { index, node in
                        MindMapOutlineBranch(node: node, path: "\(index)", color: MindMapStyle.color(for: index, scheme: colorScheme), depth: 1, collapsed: $collapsed)
                            .padding(10)
                            .background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(MindMapStyle.color(for: index, scheme: colorScheme).opacity(0.2)) }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: collapsed)
        .onChange(of: map) { _, _ in collapsed.removeAll() }
    }
}

private struct MindMapOutlineBranch: View {
    let node: MindMapNode
    let path: String
    let color: Color
    let depth: Int
    @Binding var collapsed: Set<String>
    private var expanded: Bool { !collapsed.contains(path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if node.children.isEmpty {
                row.textSelection(.enabled)
            } else {
                Button {
                    if expanded { collapsed.insert(path) } else { collapsed.remove(path) }
                } label: { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(expanded ? "收起分支" : "展开分支")
                .accessibilityLabel("\(expanded ? "收起" : "展开")：\(node.title)，\(node.children.count) 个子主题")
            }
            if expanded, !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                        MindMapOutlineBranch(node: child, path: "\(path).\(index)", color: color, depth: depth + 1, collapsed: $collapsed)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(color.opacity(0.2)).frame(width: 1).padding(.leading, 5) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("复制主题") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.title, forType: .string)
            }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: node.children.isEmpty ? "circle.fill" : expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: node.children.isEmpty ? 5 : 9, weight: .semibold))
                .foregroundStyle(color).frame(width: 12, height: 18).accessibilityHidden(true)
            Text(node.title)
                .font(.system(size: 12, weight: depth == 1 ? .semibold : .regular))
                .foregroundStyle(depth == 1 ? color : Palette.text).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            if !node.children.isEmpty {
                Text("\(node.children.count)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(color).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }
}
