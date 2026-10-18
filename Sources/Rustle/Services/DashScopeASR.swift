import Foundation

/// Native DashScope ASR protocol: final SSE sentences carry millisecond timestamps.
enum DashScopeASR {
    static let defaultBaseURL = "https://dashscope.aliyuncs.com/api/v1"
    static let defaultModel = "qwen-audio-3.0-asr-flash"
    // 16 kHz mono PCM is 32 KB/s. Three minutes stays below 10 MB after Base64.
    static let chunkDuration: TimeInterval = 180
    private static let route = "services/aigc/multimodal-generation/generation"

    static func endpoint(_ configuration: ProcessingConfiguration) throws -> URL {
        var config = configuration
        if var components = URLComponents(string: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            // Accept the shared host or a copied content-service base URL.
            if path.isEmpty || path == "compatible-mode/v1" { components.path = "/api/v1" }
            config.baseURL = components.string ?? config.baseURL
        }
        return try ProcessingEngine.apiEndpoint(config, path: route)
    }

    static func request(audio: Data, configuration: ProcessingConfiguration) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(configuration))
        let model = configuration.transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 200, !model.contains(where: \.isNewline) else {
            throw ProcessingFailure.message("请填写有效的百炼 ASR 模型名称。")
        }
        guard !audio.isEmpty, audio.count <= 7_500_000 else {
            throw ProcessingFailure.message("百炼 ASR 音频分段为空或编码后超过 10 MB，请缩短分段后重试。")
        }
        var parameters: [String: Any] = ["format": "wav", "sample_rate": "16000"]
        let locale = configuration.localeIdentifier.lowercased()
        if locale != "auto" {
            let code = locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            guard (2...3).contains(code.count), code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                throw ProcessingFailure.message("识别语言无效，请选择音频语言或自动检测。")
            }
            parameters["language_hints"] = [code]
        }
        let payload: [String: Any] = [
            "model": model,
            "input": ["messages": [["role": "user", "content": [["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64," + audio.base64EncodedString()]]]]]],
            "parameters": parameters
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        guard body.count <= 10_000_000 else { throw ProcessingFailure.message("百炼 ASR 音频分段编码后超过 10 MB，请缩短分段后重试。") }
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer " + configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = body
        return request
    }

    static func parse(_ data: Data, offset: TimeInterval, duration: TimeInterval, locale: String) throws -> TranscriptionResult {
        struct Sentence: Decodable {
            struct Word: Decodable { var begin_time: Double; var end_time: Double; var text: String; var punctuation: String? }
            var sentence_id: Int?
            var sentence_end: Bool
            var begin_time: Double
            var end_time: Double?
            var text: String
            var words: [Word]?
        }
        struct Envelope: Decodable {
            struct Output: Decodable { var text: String?; var sentence: Sentence?; var sentences: [Sentence]? }
            var output: Output?
            var code: String?
        }
        guard offset.isFinite, offset >= 0, duration.isFinite, duration > 0 else {
            throw ProcessingFailure.message("百炼 ASR 音频时间范围无效。")
        }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let payloads: [String]
        if text.hasPrefix("{") { payloads = [text] }
        else {
            payloads = text.components(separatedBy: "\n\n").compactMap { event in
                let lines = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
                let payload = lines.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                return payload.isEmpty || payload == "[DONE]" ? nil : payload
            }
        }
        guard !payloads.isEmpty else { throw ProcessingFailure.message("百炼 ASR 返回格式不正确，请检查接口地址与模型名称。") }
        var sentences: [String: Sentence] = [:]
        var pending = Set<String>()
        var recognizedText = false
        for payload in payloads {
            try Task.checkCancellation()
            let event: Envelope
            do { event = try JSONDecoder().decode(Envelope.self, from: Data(payload.utf8)) }
            catch { throw ProcessingFailure.message("百炼 ASR 返回格式不正确，请重试。") }
            // An HTTP 200 SSE response can still contain a provider error.
            if let code = event.code, !code.isEmpty, code.lowercased() != "success" {
                throw ProcessingFailure.message("百炼 ASR 识别失败，请检查模型权限、账户额度和音频格式后重试。")
            }
            guard let output = event.output else { throw ProcessingFailure.message("百炼 ASR 未返回识别结果，请重试。") }
            recognizedText = recognizedText || !(output.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            for sentence in (output.sentences ?? []) + (output.sentence.map { [$0] } ?? []) {
                let key = sentence.sentence_id.map(String.init) ?? String(sentence.begin_time)
                if sentence.sentence_end {
                    pending.remove(key)
                    sentences[key] = sentence
                } else if sentences[key] == nil { pending.insert(key) }
            }
        }
        guard pending.isEmpty, !recognizedText || !sentences.isEmpty else {
            throw ProcessingFailure.message("百炼 ASR 结果未完整返回，请重试。")
        }
        // A new sentence_id can carry the entire growing transcript from the
        // same begin_time. Retain the longest matching final snapshot before
        // splitting its words, otherwise every snapshot repeats earlier cues.
        let ordered = sentences.values.sorted {
            $0.begin_time == $1.begin_time ? ($0.sentence_id ?? 0) < ($1.sentence_id ?? 0) : $0.begin_time < $1.begin_time
        }
        let finalSentences = ordered.enumerated().filter { index, sentence in
            let content = sentence.text.filter { !$0.isWhitespace }
            guard !content.isEmpty, let end = sentence.end_time else { return true }
            return !ordered.enumerated().contains { otherIndex, other in
                guard otherIndex != index, other.begin_time == sentence.begin_time,
                      let otherEnd = other.end_time, otherEnd >= end else { return false }
                let otherContent = other.text.filter { !$0.isWhitespace }
                return otherContent.hasPrefix(content)
                    && (otherContent.count > content.count || otherEnd > end || otherIndex < index)
            }
        }.map(\.element)
        var segments: [TranscriptSegment] = []
        for sentence in finalSentences {
            let content = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            guard let end = sentence.end_time, sentence.begin_time.isFinite, end.isFinite,
                  sentence.begin_time >= 0, end >= sentence.begin_time, end / 1000 <= duration + 1 else {
                throw ProcessingFailure.message("百炼 ASR 返回了无效时间戳，请重试。")
            }
            func segment(_ content: String, begin: Double, end: Double) -> TranscriptSegment {
                let start = min(duration, begin / 1000)
                return TranscriptSegment(start: offset + start, duration: max(0, min(duration, end / 1000) - start),
                    text: LocalWhisperService.normalizedText(content.trimmingCharacters(in: .whitespacesAndNewlines), localeIdentifier: locale))
            }
            let words = sentence.words ?? []
            let wordsText = words.map { $0.text + ($0.punctuation ?? "") }.joined()
            // Split subtitles using actual word times only when they preserve all
            // recognized text; otherwise retain the valid sentence as a whole.
            let usableWords = !words.isEmpty && wordsText.filter { !$0.isWhitespace } == content.filter { !$0.isWhitespace }
                && words.allSatisfy { $0.begin_time.isFinite && $0.end_time.isFinite && $0.begin_time >= sentence.begin_time
                    && $0.end_time >= $0.begin_time && $0.end_time <= end }
                && zip(words, words.dropFirst()).allSatisfy { $0.begin_time <= $1.begin_time }
            if usableWords {
                var group = ""
                var begin = words[0].begin_time
                var groupEnd = begin
                for word in words {
                    if group.isEmpty { begin = word.begin_time }
                    group += word.text + (word.punctuation ?? "")
                    groupEnd = word.end_time
                    if group.last.map({ "。！？.!?".contains($0) }) == true || word.end_time - begin >= 12_000 {
                        if !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(segment(group, begin: begin, end: groupEnd)) }
                        group = ""
                    }
                }
                if !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(segment(group, begin: begin, end: groupEnd)) }
            } else { segments.append(segment(content, begin: sentence.begin_time, end: end)) }
        }
        return TranscriptionResult(segments: TranscriptSegment.mergingCumulativeResults(segments), duration: duration, language: locale)
    }
}
