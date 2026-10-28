import Foundation

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "全部记录", favorites = "已收藏"
    var id: String { rawValue }
}

enum SourceKind: String, Codable {
    case audio, video, link, microphone
    // Decode records created by the earlier text-note implementation.
    case legacyNote = "note"
    var symbol: String { switch self { case .audio: "waveform"; case .video: "video"; case .link: "link"; case .microphone: "mic"; case .legacyNote: "doc.text" } }
    var label: String { switch self { case .audio: "音频"; case .video: "视频"; case .link: "链接"; case .microphone: "录音"; case .legacyNote: "文字" } }
}

enum RecordStatus: String, Codable {
    case ready, processing, failed
}

struct TranscriptSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: TimeInterval
    var duration: TimeInterval
    var text: String
    var speaker: String = "发言人"

    /// Some ASR events repeat an expanding prefix under a new sentence ID.
    /// Merge only matching text at the same time and speaker; speech repeated
    /// later in the recording must remain intact. Keep the first ID for ties.
    static func mergingCumulativeResults(_ segments: [Self]) -> [Self] {
        struct Position: Hashable { var start: TimeInterval; var speaker: String }
        var groups: [Position: [(index: Int, segment: Self)]] = [:]
        func covers(_ lhs: Self, _ rhs: Self) -> Bool {
            let text = rhs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && lhs.duration >= rhs.duration
                && lhs.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(text)
        }
        for (index, segment) in segments.enumerated() {
            let position = Position(start: segment.start, speaker: segment.speaker)
            var group = groups[position] ?? []
            if group.contains(where: { covers($0.segment, segment) }) { continue }
            group.removeAll { covers(segment, $0.segment) }
            group.append((index, segment))
            groups[position] = group
        }
        var retained: [(index: Int, segment: Self)] = groups.values.flatMap { $0 }
        retained.sort { lhs, rhs in
            if lhs.segment.start == rhs.segment.start { return lhs.index < rhs.index }
            return lhs.segment.start < rhs.segment.start
        }
        return retained.map { $0.segment }
    }
}

struct ActionItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var owner: String = "待分配"
    var dueDate: String = "未设截止日期"
    var isCompleted = false
}

struct MeetingInsights: Codable, Equatable {
    var summary: String
    var keyPoints: [String]
    var tasks: [ActionItem]
    var isAIGenerated: Bool = false
}

enum InsightFeature: String, Codable, CaseIterable, Identifiable {
    case overview, mindMap, tasks, followUp, translation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "概览"
        case .mindMap: "思维导图"
        case .tasks: "待办"
        case .followUp: "追问"
        case .translation: "SRT 翻译"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "text.alignleft"
        case .mindMap: "point.3.connected.trianglepath.dotted"
        case .tasks: "checklist"
        case .followUp: "bubble.left.and.bubble.right"
        case .translation: "captions.bubble"
        }
    }
}

struct ContentOverview: Codable, Equatable {
    var summary: String
    var keyPoints: [String]
}

struct MindMapNode: Codable, Equatable {
    var title: String
    var children: [MindMapNode]

    init(title: String, children: [MindMapNode] = []) {
        self.title = title
        self.children = children
    }

    var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }

    private enum CodingKeys: String, CodingKey { case title, children }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        // Compatible services may omit children or return null for leaves.
        // Other types still fail decoding so branches are never silently lost.
        children = try container.decodeIfPresent([MindMapNode].self, forKey: .children) ?? []
    }
}

struct FollowUpAnswer: Identifiable, Codable, Equatable {
    var id = UUID()
    var question: String
    var answer: String
}

enum SubtitleLanguage: String, Codable, CaseIterable, Identifiable {
    case simplifiedChinese = "简体中文", traditionalChinese = "繁体中文", english = "英语", japanese = "日语", korean = "韩语", french = "法语", german = "德语", spanish = "西班牙语"
    var id: String { rawValue }
}

struct SubtitleTranslation: Codable, Equatable {
    var language: SubtitleLanguage
    var segments: [TranscriptSegment]
}

// Optional results distinguish an unrequested feature from a generated empty result.
struct ContentInsights: Codable, Equatable {
    var overview: ContentOverview?
    var mindMap: MindMapNode?
    var tasks: [ActionItem]?
    var answers: [FollowUpAnswer]?
    var translation: SubtitleTranslation?
    var errors: [String: String]?
}

struct TranscriptionResult {
    var segments: [TranscriptSegment]
    var duration: TimeInterval
    var language: String
}

struct Recording: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var duration: TimeInterval
    var sourceKind: SourceKind
    var sourceURL: String?
    var localMediaPath: String?
    var language = "中文"
    var isFavorite = false
    var status: RecordStatus = .ready
    var segments: [TranscriptSegment]
    var insights: MeetingInsights?
    var errorMessage: String?
    var insightsError: String?
    var isDemo = false
    var contentInsights: ContentInsights?
    // Markdown source is persisted independently of ASR and generated insights.
    var notes: String?
    var noteText: String { notes ?? "" }
    var hasExportableContent: Bool { !segments.isEmpty || !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var transcript: String { segments.map(\.text).joined(separator: "\n") }
    var apiInsights: MeetingInsights? { isDemo || insights?.isAIGenerated == true ? insights : nil }
    var overview: ContentOverview? {
        contentInsights?.overview ?? apiInsights.map { ContentOverview(summary: $0.summary, keyPoints: $0.keyPoints) }
    }
    var actionItems: [ActionItem]? { contentInsights?.tasks ?? apiInsights?.tasks }
    func hasInsight(_ feature: InsightFeature) -> Bool {
        switch feature {
        case .overview: overview != nil
        case .mindMap: contentInsights?.mindMap != nil
        case .tasks: actionItems != nil
        case .followUp: !(contentInsights?.answers ?? []).isEmpty
        case .translation: contentInsights?.translation != nil
        }
    }

    @discardableResult mutating func discardLegacyInsights() -> Bool {
        guard !isDemo, let insights, !insights.isAIGenerated else { return false }
        self.insights = nil
        return true
    }

    @discardableResult mutating func repairTranscriptTimeline() -> Bool {
        let repaired = TranscriptSegment.mergingCumulativeResults(segments)
        var translation = contentInsights?.translation
        if let cues = translation?.segments {
            translation?.segments = TranscriptSegment.mergingCumulativeResults(cues)
        }
        guard repaired != segments || translation != contentInsights?.translation else { return false }
        segments = repaired
        contentInsights?.translation = translation
        return true
    }
}

enum TranscriptionProvider: String, Codable, CaseIterable, Identifiable {
    case whisperCpp = "本地 Whisper · 开源"
    case dashScope = "阿里云百炼 ASR"
    var id: String { rawValue }
}

struct ProcessingConfiguration {
    var provider: TranscriptionProvider = .whisperCpp
    var localeIdentifier = "zh-CN"
    var whisperExecutablePath = ""
    var whisperModelPath = ""
    var whisperUseGPU = true
    var apiKey = ""
    var baseURL = DashScopeASR.defaultBaseURL
    var transcriptionModel = DashScopeASR.defaultModel
    var insightsBaseURL = "https://api.openai.com/v1"
    var insightsAPIKey = ""
    var summaryModel = "gpt-4o-mini"

    var insightsConfiguration: Self {
        var configuration = self
        configuration.baseURL = insightsBaseURL
        configuration.apiKey = insightsAPIKey
        return configuration
    }
}

extension TimeInterval {
    var timestamp: String {
        let seconds = max(0, Int(self.isFinite ? self : 0))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var durationLabel: String {
        let minutes = max(1, Int((self.isFinite ? self : 0) / 60))
        return "\(minutes) 分钟"
    }
}
