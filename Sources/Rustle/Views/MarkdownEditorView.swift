import AppKit
import SwiftUI
import WebKit

@MainActor
final class MarkdownEditorController: ObservableObject {
    @Published fileprivate(set) var isReady = false
    @Published fileprivate(set) var errorMessage: String?
    fileprivate weak var webView: WKWebView?

    func reset() { isReady = false; errorMessage = nil }

    func markdown() async throws -> String {
        guard isReady, let webView else {
            throw ProcessingFailure.message("Markdown 编辑器尚未就绪，请稍后重试。")
        }
        guard let markdown = try await webView.callAsyncJavaScript("return window.rustleNotes.getMarkdown()", arguments: [:], in: nil, contentWorld: .page) as? String else {
            throw ProcessingFailure.message("未能读取笔记内容，请重试。")
        }
        return markdown
    }
}

struct MarkdownEditorView: NSViewRepresentable {
    let markdown: String
    let onChange: (String) -> Void
    @ObservedObject var controller: MarkdownEditorController

    func makeCoordinator() -> Coordinator { Coordinator(markdown: markdown, onChange: onChange, controller: controller) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "noteEditor")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .clear
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controller.webView = view
        if let url = Self.resourceURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { controller.errorMessage = "未找到笔记编辑器资源，请重新构建或安装 Rustle。" }
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onChange = onChange
        guard context.coordinator.modelMarkdown != markdown else { return }
        context.coordinator.modelMarkdown = markdown
        if controller.isReady { context.coordinator.loadContent(in: view) }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "noteEditor")
        view.navigationDelegate = nil
    }

    static var resourceURL: URL? {
        // Packaged apps keep the SwiftPM resource bundle inside Resources/.
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("Rustle_Rustle.bundle")),
           let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: "NotesEditor") { return url }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "NotesEditor")
        #else
        return nil
        #endif
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var modelMarkdown: String
        var onChange: (String) -> Void
        private let controller: MarkdownEditorController

        init(markdown: String, onChange: @escaping (String) -> Void, controller: MarkdownEditorController) {
            modelMarkdown = markdown; self.onChange = onChange; self.controller = controller
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                if let view = message.webView { loadContent(in: view) }
            case "change":
                guard let markdown = body["markdown"] as? String, markdown != modelMarkdown else { return }
                // Update this before publishing to SwiftUI, preserving the caret and undo history.
                modelMarkdown = markdown
                onChange(markdown)
            case "error": controller.errorMessage = body["message"] as? String ?? "笔记编辑器出现错误。"
            case "openLink":
                if let value = body["url"] as? String, let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
            default: break
            }
        }

        func loadContent(in view: WKWebView) {
            view.callAsyncJavaScript("window.rustleNotes.load(markdown)", arguments: ["markdown": modelMarkdown], in: nil, in: .page) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.controller.isReady = true; self.controller.errorMessage = nil
                case .failure: self.controller.errorMessage = "Markdown 编辑器初始化失败，请重新打开此笔记。"
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Editor contents can only navigate to their bundled local resource.
            if navigationAction.navigationType == .other, let url = navigationAction.request.url, url.isFileURL {
                decisionHandler(.allow)
            } else { decisionHandler(.cancel) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            controller.errorMessage = "笔记编辑器加载失败：\(error.localizedDescription)"
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            controller.isReady = false
            controller.errorMessage = "笔记编辑器已停止，请重新打开此笔记。已保存的内容仍在本机。"
        }
    }
}
