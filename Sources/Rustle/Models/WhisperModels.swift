import Foundation

struct WhisperModelDefinition: Identifiable, Equatable {
    let id: String
    let title: String
    let sizeLabel: String
    let sha1: String
    var filename: String { "ggml-\(id).bin" }

    // Checksums from whisper.cpp v1.9.5 models/README.md.
    static let catalog: [Self] = [
        .init(id: "tiny", title: "Tiny · 轻量快速", sizeLabel: "75 MiB", sha1: "bd577a113a864445d4c299885e0cb97d4ba92b5f"),
        .init(id: "base", title: "Base · 入门", sizeLabel: "142 MiB", sha1: "465707469ff3a37a2b9b8d8f89f2f99de7299dac"),
        .init(id: "small", title: "Small · 均衡", sizeLabel: "466 MiB", sha1: "55356645c2b361a969dfd0ef2c5a50d530afd8d5"),
        .init(id: "medium", title: "Medium · 更高精度", sizeLabel: "1.5 GiB", sha1: "fd9727b6e1217c2f614f9b698455c4ffd82463b4"),
        .init(id: "large-v3-turbo-q5_0", title: "Large v3 Turbo · Q5 量化", sizeLabel: "547 MiB", sha1: "e050f7970618a659205450ad97eb95a18d69c9ee"),
        .init(id: "large-v3-turbo", title: "Large v3 Turbo", sizeLabel: "1.5 GiB", sha1: "4af2b29d7ec73d781377bfd1758ca957a807e941"),
        .init(id: "large-v3", title: "Large v3 · 完整模型", sizeLabel: "2.9 GiB", sha1: "ad82bf6a9043ceed055076d0fd39f5f186ff8062")
    ]
}

enum WhisperDownloadSource: String, CaseIterable, Identifiable {
    case huggingFace, hfMirror, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .huggingFace: "Hugging Face · 官方模型仓库"; case .hfMirror: "HF Mirror · 镜像"; case .custom: "自定义下载地址" }
    }

    func url(for model: WhisperModelDefinition, customAddress: String = "") throws -> URL {
        guard !model.id.isEmpty, !model.id.hasPrefix("."), model.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            throw ProcessingFailure.message("模型名称无效。")
        }
        let address: String
        switch self {
        case .huggingFace: address = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(model.filename)"
        case .hfMirror: address = "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/\(model.filename)"
        case .custom:
            let input = customAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else { throw ProcessingFailure.message("请填写自定义下载地址。") }
            if input.contains("{filename}") { address = input.replacingOccurrences(of: "{filename}", with: model.filename) }
            else if let url = URL(string: input), url.pathExtension.lowercased() == "bin" { address = input }
            else {
                guard let url = URL(string: input) else { throw ProcessingFailure.message("自定义下载地址格式不正确。") }
                address = url.appendingPathComponent(model.filename).absoluteString
            }
        }
        guard let url = URL(string: address), Self.isAllowed(url) else {
            throw ProcessingFailure.message("下载地址须为 HTTPS；本机服务可用 HTTP。请移除地址中的用户名和密码。")
        }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
    }

    func fallbackSources(enabled: Bool) -> [Self] {
        guard enabled, self != .custom else { return [self] }
        return [self, self == .huggingFace ? .hfMirror : .huggingFace]
    }
}

enum ModelDownloadUpdate: Sendable {
    case downloading(received: Int64, total: Int64)
    case verifying
}
