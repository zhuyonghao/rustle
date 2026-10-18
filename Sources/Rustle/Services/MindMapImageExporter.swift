import AppKit
import SwiftUI

enum MindMapStyle {
    private static let lightColors: [Color] = [Color(hex: 0x4168B0), Color(hex: 0x287B70), Color(hex: 0x8654AC),
                                                Color(hex: 0xAC692E), Color(hex: 0xB44F73), Color(hex: 0x3A7E9F)]
    private static let darkColors: [Color] = [Color(hex: 0x91B2FF), Color(hex: 0x7ACABC), Color(hex: 0xC5A0E9),
                                               Color(hex: 0xE9B37D), Color(hex: 0xED9AB8), Color(hex: 0x88C6E5)]

    static func color(for branch: Int, scheme: ColorScheme = .light) -> Color {
        let colors = scheme == .dark ? darkColors : lightColors
        return colors[branch % colors.count]
    }

    static func fontSize(depth: Int) -> CGFloat { depth == 0 ? 17 : depth == 1 ? 14 : 13 }
}

/// Shared geometry keeps the full-window diagram and PNG export identical.
struct MindMapLayout {
    struct Node: Identifiable {
        var id: Int
        var title: String
        var frame: CGRect
        var depth: Int
        var branch: Int
    }
    struct Connection {
        var start: CGPoint
        var end: CGPoint
        var branch: Int
    }

    var nodes: [Node] = []
    var connections: [Connection] = []
    var size: CGSize = .zero

    init(map: MindMapNode) {
        let width: CGFloat = 240
        let columnGap: CGFloat = 64
        let rowGap: CGFloat = 18
        let margin: CGFloat = 36
        let top: CGFloat = 116
        struct MeasuredNode {
            var source: MindMapNode
            var height: CGFloat
            var subtreeHeight: CGFloat
            var children: [MeasuredNode]
        }
        func measure(_ node: MindMapNode, depth: Int) -> MeasuredNode {
            let font = NSFont.systemFont(ofSize: MindMapStyle.fontSize(depth: depth), weight: depth <= 1 ? .semibold : .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            let text = (node.title as NSString).boundingRect(with: CGSize(width: width - 36, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph])
            let minimumHeight: CGFloat = depth == 0 ? 72 : depth == 1 ? 60 : 50
            let height = max(minimumHeight, ceil(text.height) + 32)
            let children = node.children.map { measure($0, depth: depth + 1) }
            let childrenHeight = children.reduce(CGFloat.zero) { $0 + $1.subtreeHeight } + CGFloat(max(0, children.count - 1)) * rowGap
            return MeasuredNode(source: node, height: height, subtreeHeight: max(height, childrenHeight), children: children)
        }
        let root = measure(map, depth: 0)
        func place(_ node: MeasuredNode, depth: Int, y: CGFloat, branch: Int) {
            let frame = CGRect(x: margin + CGFloat(depth) * (width + columnGap),
                               y: y + (node.subtreeHeight - node.height) / 2, width: width, height: node.height)
            nodes.append(Node(id: nodes.count, title: node.source.title, frame: frame, depth: depth, branch: branch))
            let childrenHeight = node.children.reduce(CGFloat.zero) { $0 + $1.subtreeHeight } + CGFloat(max(0, node.children.count - 1)) * rowGap
            var childY = y + (node.subtreeHeight - childrenHeight) / 2
            for (index, child) in node.children.enumerated() {
                let childBranch = depth == 0 ? index : branch
                connections.append(Connection(start: CGPoint(x: frame.maxX, y: frame.midY),
                    end: CGPoint(x: frame.maxX + columnGap, y: childY + child.subtreeHeight / 2), branch: childBranch))
                place(child, depth: depth + 1, y: childY, branch: childBranch)
                childY += child.subtreeHeight + rowGap
            }
        }
        place(root, depth: 0, y: top, branch: 0)
        size = CGSize(width: max(600, (nodes.map(\.frame.maxX).max() ?? 0) + margin), height: top + root.subtreeHeight + margin)
    }
}

struct MindMapDiagram: View {
    let title: String
    let layout: MindMapLayout
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Export always supplies a light color scheme and an opaque white canvas.
            (colorScheme == .dark ? Color(hex: 0x202226) : Color.white)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 18, weight: .semibold))
                    .lineLimit(2)
                Text("思维导图 · \(layout.nodes.count) 个节点")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: layout.size.width - 72, height: 76, alignment: .topLeading)
            .offset(x: 36, y: 24)
            Canvas { context, _ in
                for connection in layout.connections {
                    let middle = (connection.start.x + connection.end.x) / 2
                    var path = Path()
                    path.move(to: connection.start)
                    path.addCurve(to: connection.end, control1: CGPoint(x: middle, y: connection.start.y), control2: CGPoint(x: middle, y: connection.end.y))
                    context.stroke(path, with: .color(MindMapStyle.color(for: connection.branch, scheme: colorScheme).opacity(0.48)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }.accessibilityHidden(true)
            ForEach(layout.nodes) { node in
                nodeCard(node).position(x: node.frame.midX, y: node.frame.midY)
            }
        }.frame(width: layout.size.width, height: layout.size.height)
    }

    private func nodeCard(_ node: MindMapLayout.Node) -> some View {
        let color = MindMapStyle.color(for: node.branch, scheme: colorScheme)
        let shape = RoundedRectangle(cornerRadius: node.depth == 0 ? 14 : 10)
        return Text(node.title)
            .font(.system(size: MindMapStyle.fontSize(depth: node.depth), weight: node.depth <= 1 ? .semibold : .regular))
            .foregroundStyle(node.depth == 0 ? Color.white : Color.primary)
            .multilineTextAlignment(.leading).lineSpacing(4)
            .frame(width: node.frame.width - 36, height: node.frame.height - 32, alignment: .leading)
            .frame(width: node.frame.width, height: node.frame.height)
            .background {
                if node.depth == 0 {
                    shape.fill(LinearGradient(colors: [Color(hex: 0x4D73CB), Color(hex: 0x3659AB)], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    shape.fill(color.opacity(node.depth == 1 ? 0.10 : 0.035))
                }
            }
            .overlay { shape.strokeBorder(color.opacity(node.depth == 0 ? 0 : node.depth == 1 ? 0.4 : 0.2), lineWidth: 1) }
            .overlay(alignment: .leading) {
                if node.depth == 1 {
                    Capsule().fill(color).frame(width: 3, height: 20).padding(.leading, 7)
                }
            }
            .shadow(color: node.depth == 0 ? Color(hex: 0x3659AB).opacity(0.16) : .clear, radius: 8, y: 4)
            .accessibilityLabel("\(node.depth == 0 ? "中心主题" : "第 \(node.depth) 级主题")：\(node.title)")
    }
}

enum MindMapImageExporter {
    @MainActor
    static func pngData(map: MindMapNode, title: String) throws -> Data {
        let layout = MindMapLayout(map: map)
        let renderer = ImageRenderer(content: MindMapDiagram(title: title, layout: layout).environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(layout.size)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ProcessingFailure.message("无法生成思维导图图片，请重试。")
        }
        return data
    }
}
