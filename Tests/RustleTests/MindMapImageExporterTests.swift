import XCTest
import AppKit
@testable import Rustle

final class MindMapImageExporterTests: XCTestCase {
    func testLayoutIncludesEveryNodeAndKeepsBoxesInsideImage() {
        let map = MindMapNode(title: "交付计划", children: [
            MindMapNode(title: "设计", children: [MindMapNode(title: "确定方案"), MindMapNode(title: "评审")]),
            MindMapNode(title: "验收", children: [MindMapNode(title: "记录结果")])
        ])
        let layout = MindMapLayout(map: map)
        XCTAssertEqual(layout.nodes.map(\.title), ["交付计划", "设计", "确定方案", "评审", "验收", "记录结果"])
        XCTAssertEqual(layout.connections.count, layout.nodes.count - 1)
        let bounds = CGRect(origin: .zero, size: layout.size)
        for node in layout.nodes { XCTAssertTrue(bounds.contains(node.frame), "Node must not be clipped: \(node.title)") }
        for (index, node) in layout.nodes.enumerated() {
            for other in layout.nodes.dropFirst(index + 1) { XCTAssertFalse(node.frame.intersects(other.frame), "Node boxes must not overlap") }
        }
        for connection in layout.connections {
            XCTAssertTrue(layout.nodes.contains { $0.frame.maxX == connection.start.x && $0.frame.midY == connection.start.y })
            XCTAssertTrue(layout.nodes.contains { $0.frame.minX == connection.end.x && $0.frame.midY == connection.end.y })
        }
    }

    func testLongChineseTitlesAndSixtyNodesRemainComplete() {
        let branches = [7, 7, 7, 7, 6, 6, 6, 5].enumerated().map { index, count in
            MindMapNode(title: "分支\(index)", children: (0..<count).map {
                MindMapNode(title: "\(index)-\($0) " + String(repeating: "需要完整显示的中文细节🙂", count: 4))
            })
        }
        let layout = MindMapLayout(map: MindMapNode(title: "完整导图", children: branches))
        XCTAssertEqual(layout.nodes.count, 60)
        XCTAssertEqual(layout.connections.count, 59)
        XCTAssertGreaterThan(layout.size.height, 1000)
        let bounds = CGRect(origin: .zero, size: layout.size)
        XCTAssertTrue(layout.nodes.allSatisfy { bounds.contains($0.frame) })
        XCTAssertTrue(layout.nodes.filter { $0.depth == 2 }.allSatisfy { $0.frame.height > 50 })
    }

    @MainActor
    func testPNGIsHighResolutionAndCoversEntireLayout() throws {
        let map = MindMapNode(title: "项目计划", children: [MindMapNode(title: "设计", children: [MindMapNode(title: "确定方案🙂")]), MindMapNode(title: "验收")])
        let layout = MindMapLayout(map: map)
        let data = try MindMapImageExporter.pngData(map: map, title: "中文记录 · 图片导出")
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        guard let bitmap = NSBitmapImageRep(data: data) else { XCTFail("Export must be a valid PNG"); return }
        XCTAssertEqual(bitmap.pixelsWide, Int(ceil(layout.size.width * 2)))
        XCTAssertEqual(bitmap.pixelsHigh, Int(ceil(layout.size.height * 2)))
        // The bottom-right background must be opaque and white, including in dark mode.
        let background = bitmap.colorAt(x: bitmap.pixelsWide - 2, y: bitmap.pixelsHigh - 2)?.usingColorSpace(.deviceRGB)
        XCTAssertEqual(Double(background?.alphaComponent ?? 0), 1, accuracy: 0.01)
        XCTAssertGreaterThan(Double(background?.redComponent ?? 0), 0.98)
    }

    @MainActor
    func testRootOnlyMapAlsoExports() throws {
        let map = MindMapNode(title: "只有一个主题")
        let layout = MindMapLayout(map: map)
        XCTAssertEqual(layout.nodes.count, 1)
        XCTAssertEqual(layout.connections.count, 0)
        let data = try MindMapImageExporter.pngData(map: map, title: "简短文稿")
        XCTAssertNotNil(NSBitmapImageRep(data: data))
    }
}
