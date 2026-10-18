import AppKit
import Foundation

guard (2...3).contains(CommandLine.arguments.count) else {
    fputs("Usage: swift create-icon.swift <output.iconset> [output.icns]\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()

    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(srgbRed: 0.11, green: 0.19, blue: 0.17, alpha: 1), ending: NSColor(srgbRed: 0.07, green: 0.11, blue: 0.11, alpha: 1))?.draw(in: background, angle: 90)

    NSColor(srgbRed: 0.55, green: 0.87, blue: 0.73, alpha: 0.11).setStroke()
    background.lineWidth = 3
    background.stroke()

    let bars: [(CGFloat, CGFloat)] = [(290, 168), (386, 302), (482, 438), (578, 338), (674, 206)]
    for (x, height) in bars {
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: 512 - height / 2, width: 60, height: height), xRadius: 30, yRadius: 30)
        NSGradient(starting: NSColor(srgbRed: 0.47, green: 0.79, blue: 0.64, alpha: 1), ending: NSColor(srgbRed: 0.79, green: 0.98, blue: 0.88, alpha: 1))?.draw(in: bar, angle: 90)
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        guard let data = drawIcon(pixels: size * scale) else {
            fputs("Unable to draw icon.\n", stderr)
            exit(1)
        }
        try data.write(to: output.appendingPathComponent(filename), options: .atomic)
    }
}

if CommandLine.arguments.count == 3 {
    // PNG-backed ICNS entries avoid iconutil's sandbox-sensitive conversion service.
    let representations = [
        ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"),
    ]
    func lengthBytes(_ length: Int) -> Data {
        var value = UInt32(length).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    var entries = Data()
    for (type, filename) in representations {
        let image = try Data(contentsOf: output.appendingPathComponent(filename))
        entries.append(Data(type.utf8))
        entries.append(lengthBytes(image.count + 8))
        entries.append(image)
    }
    var container = Data("icns".utf8)
    container.append(lengthBytes(entries.count + 8))
    container.append(entries)
    try container.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
}
