import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case text = "纯文本"
    case srt = "SRT 字幕"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .text: "txt"
        case .srt: "srt"
        }
    }
}

enum TranscriptExporter {
    static func export(_ recording: Recording, format: ExportFormat) -> String {
        switch format {
        case .markdown: markdown(recording)
        case .text: plainText(recording)
        case .srt: subtitles(recording)
        }
    }

    private static func markdown(_ recording: Recording) -> String {
        var lines = ["# \(escapeMarkdown(singleLine(recording.title)))", "", metadata(recording)]
        if let insights = recording.overview {
            lines += ["", "## 内容总结", "", escapeMarkdown(insights.summary)]
            if !insights.keyPoints.isEmpty {
                lines += ["", "## 关键要点", ""]
                lines += insights.keyPoints.map { "- \(escapeMarkdown(singleLine($0)))" }
            }
        }
        if let tasks = recording.actionItems, !tasks.isEmpty {
                lines += ["", "## 待办事项", ""]
                lines += tasks.map { task in
                    "- [\(task.isCompleted ? "x" : " ")] \(escapeMarkdown(singleLine(task.title)))（负责人：\(escapeMarkdown(singleLine(task.owner)))；截止：\(escapeMarkdown(singleLine(task.dueDate)))）"
                }
        }
        lines += ["", "## 转写原文", ""]
        for segment in orderedSegments(recording) {
            let speaker = singleLine(segment.speaker)
            let heading = "\(displayTime(segment.start)) – \(displayTime(segmentEnd(segment)))\(speaker.isEmpty ? "" : " · \(escapeMarkdown(speaker))")"
            lines += ["**\(heading)**", "", escapeMarkdown(segment.text), ""]
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func plainText(_ recording: Recording) -> String {
        var lines = [singleLine(recording.title), metadata(recording)]
        if let insights = recording.overview {
            lines += ["", "内容总结", clean(insights.summary)]
            if !insights.keyPoints.isEmpty {
                lines += ["", "关键要点"]
                lines += insights.keyPoints.enumerated().map { "\($0.offset + 1). \(clean($0.element))" }
            }
        }
        if let tasks = recording.actionItems, !tasks.isEmpty {
                lines += ["", "待办事项"]
                lines += tasks.map { task in
                    "[\(task.isCompleted ? "已完成" : "待完成")] \(singleLine(task.title))（负责人：\(singleLine(task.owner))；截止：\(singleLine(task.dueDate))）"
                }
        }
        lines += ["", "转写原文"]
        for segment in orderedSegments(recording) {
            let speaker = singleLine(segment.speaker)
            lines += ["", "[\(displayTime(segment.start)) – \(displayTime(segmentEnd(segment)))]\(speaker.isEmpty ? "" : " \(speaker)")", clean(segment.text)]
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func subtitles(_ recording: Recording) -> String {
        let segments = orderedSegments(recording).filter { !clean($0.text).isEmpty }
        let cues = segments.enumerated().map { index, segment in
            let start = milliseconds(segment.start)
            let end = max(start + 1, milliseconds(segmentEnd(segment)))
            let content = clean(segment.text).components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let speaker = singleLine(segment.speaker)
            let caption = speaker.isEmpty || speaker == "发言人" ? content : "\(speaker)：\(content)"
            let escaped = caption.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "\(index + 1)\n\(srtTime(start)) --> \(srtTime(end))\n\(escaped)"
        }
        return cues.isEmpty ? "" : cues.joined(separator: "\n\n") + "\n"
    }

    private static func orderedSegments(_ recording: Recording) -> [TranscriptSegment] {
        recording.segments.enumerated().sorted { lhs, rhs in
            let left = normalizedTime(lhs.element.start)
            let right = normalizedTime(rhs.element.start)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private static func metadata(_ recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return "\(formatter.string(from: recording.createdAt)) · \(recording.sourceKind.label) · \(displayTime(recording.duration))\(recording.isDemo ? " · 演示内容" : "")"
    }

    private static func normalizedTime(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        // This upper bound keeps integer conversion safe even for malformed input.
        return min(max(value, 0), 1_000_000_000_000)
    }

    private static func segmentEnd(_ segment: TranscriptSegment) -> TimeInterval {
        normalizedTime(segment.start) + normalizedTime(segment.duration)
    }

    private static func milliseconds(_ value: TimeInterval) -> Int64 {
        Int64((normalizedTime(value) * 1000).rounded())
    }

    private static func displayTime(_ value: TimeInterval) -> String {
        let total = Int64(normalizedTime(value).rounded(.down))
        if total >= 3600 { return String(format: "%lld:%02lld:%02lld", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02lld:%02lld", total / 60, total % 60)
    }

    private static func srtTime(_ value: Int64) -> String {
        String(format: "%02lld:%02lld:%02lld,%03lld", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, value % 1000)
    }

    private static func clean(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let scalars = normalized.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0.value == 10 || $0.value == 9
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func singleLine(_ value: String) -> String {
        clean(value).components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func escapeMarkdown(_ value: String) -> String {
        let entities = clean(value).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let special = Set("\\`*_{}[]()#+-.!|~")
        return entities.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
            .replacingOccurrences(of: "\n", with: "  \n")
    }
}
