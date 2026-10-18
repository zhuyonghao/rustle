import Foundation

struct ProcessingProgress: Sendable {
    var title: String
    var fraction: Double? = nil
    var detail: String = ""
    var percentLabel: String? { fraction.map { "\(Int(min(1, max(0, $0)) * 100))%" } }

    static func download(received: Int64, total: Int64, speed: Double? = nil, eta: Double? = nil, estimated: Bool = false) -> Self {
        func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, n), countStyle: .file) }
        var detail = total > 0 ? "\(bytes(received)) / \(estimated ? "约 " : "")\(bytes(total))" : "已下载 \(bytes(received)) · 总大小未知"
        if let speed, speed.isFinite, speed > 0 { detail += " · \(bytes(Int64(min(speed, Double(Int64.max / 2)))))/s" }
        if let eta, eta.isFinite, eta >= 0 { detail += " · 剩余约 \(eta.timestamp)" }
        return Self(title: "正在下载媒体", fraction: total > 0 ? min(1, max(0, Double(received) / Double(total))) : nil, detail: detail)
    }

    static func transcription(offset: Double, chunkDuration: Double, duration: Double, fraction: Double?, local: Bool = true, chunkInterval: Double? = nil) -> Self {
        let processed = offset + chunkDuration * (fraction ?? 0)
        let interval = chunkInterval ?? (local ? 600 : 300)
        let index = Int(offset / interval) + 1
        let count = Int(ceil(duration / interval))
        return Self(title: local ? "本地 Whisper 正在转写" : "正在等待识别服务", fraction: fraction.map { _ in min(1, max(0, processed / duration)) }, detail: "已处理 \(processed.timestamp) / \(duration.timestamp) · 第 \(index)/\(count) 段" + (fraction == nil ? " · 服务未提供段内进度" : ""))
    }
}

/// Only machine-readable progress lines are accepted; downloader diagnostics never enter the UI.
enum MediaProgressParser {
    static let downloadPrefix = "__RUSTLE_DOWNLOAD__"
    static let filePrefix = "__RUSTLE_FILE__"
    static let titlePrefix = "__RUSTLE_TITLE__"
    static let template = "download:" + downloadPrefix + "{\"downloaded_bytes\":%(progress.downloaded_bytes|0)j,\"total_bytes\":%(progress.total_bytes|0)j,\"total_bytes_estimate\":%(progress.total_bytes_estimate|0)j,\"speed\":%(progress.speed|0)j,\"eta\":%(progress.eta|0)j}"

    static func download(_ line: String) -> ProcessingProgress? {
        guard line.hasPrefix(downloadPrefix), let data = line.dropFirst(downloadPrefix.count).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let received = object["downloaded_bytes"] as? NSNumber, received.doubleValue.isFinite, received.doubleValue >= 0 else { return nil }
        let total = (object["total_bytes"] as? NSNumber)?.int64Value ?? 0
        let estimate = (object["total_bytes_estimate"] as? NSNumber)?.int64Value ?? 0
        return .download(received: received.int64Value, total: total > 0 ? total : estimate, speed: (object["speed"] as? NSNumber)?.doubleValue, eta: (object["eta"] as? NSNumber)?.doubleValue, estimated: total <= 0 && estimate > 0)
    }
    static func filepath(_ line: String) -> String? {
        guard line.hasPrefix(filePrefix), let data = line.dropFirst(filePrefix.count).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
    static func mediaTitle(_ line: String) -> String? {
        guard line.hasPrefix(titlePrefix), let data = line.dropFirst(titlePrefix.count).data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title == "NA" ? nil : title
    }
    static func whisper(_ line: String) -> Double? {
        guard let range = line.range(of: #"progress\s*=\s*([0-9]{1,3})%"#, options: .regularExpression) else { return nil }
        let digits = line[range].filter(\.isNumber)
        guard let value = Double(digits), (0...100).contains(value) else { return nil }
        return value / 100
    }
}
