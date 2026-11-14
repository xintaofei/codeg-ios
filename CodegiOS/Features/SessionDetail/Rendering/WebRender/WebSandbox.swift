import SwiftUI
import UIKit
import WebKit

/// The lock-down every WebKit view in the app shares — the off-screen
/// renderer's pages and the full-screen diagram / HTML viewers:
///
/// - a non-persistent data store (no cookies, storage or cache on disk);
/// - a content rule list that blocks every load but `about:`, `data:` and
///   `blob:` — nothing reaches the network or the file system (the bundled
///   Mermaid script is handed to the page by the app, not loaded by it);
/// - content JavaScript off by default (`SandboxNavigationGuard` turns it on
///   only for the renderer's own Mermaid page);
/// - a navigation delegate that lets exactly one load through — the document
///   the app hands the view — and cancels every other navigation (links, meta
///   refresh, form submissions);
/// - no data detectors, link previews, media autoplay, AirPlay or PiP.
@MainActor
enum WebSandbox {
    static let dataStore = WKWebsiteDataStore.nonPersistent()

    /// WebKit content-rule regexes have no alternation, so one rule a scheme.
    static let ruleListJSON = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """
    private static let ruleListIdentifier = "codeg.web-sandbox.offline.v1"

    private static var compiled: WKContentRuleList?
    private static var compiling: Task<WKContentRuleList, Error>?

    /// The compiled rule list, compiled once per process. A failure is not
    /// cached: the next caller tries again. Nothing loads without it.
    static func blockingRules() async throws -> WKContentRuleList {
        if let compiled { return compiled }
        if let compiling { return try await compiling.value }
        let task = Task { @MainActor () async throws -> WKContentRuleList in
            try await withCheckedThrowingContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: ruleListIdentifier, encodedContentRuleList: ruleListJSON
                ) { list, error in
                    if let list {
                        continuation.resume(returning: list)
                    } else {
                        continuation.resume(throwing: error ?? WebRenderError.unavailable)
                    }
                }
            }
        }
        compiling = task
        defer { compiling = nil }
        let list = try await task.value
        compiled = list
        return list
    }

    /// A locked-down configuration around `controller`. Add the rule list to
    /// the controller before the first load.
    static func configuration(controller: WKUserContentController) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.userContentController = controller
        // Assigned whole: the property copies on set, and mutating what the
        // getter hands back is not guaranteed to reach the configuration.
        let page = WKWebpagePreferences()
        page.allowsContentJavaScript = false
        config.defaultWebpagePreferences = page
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.dataDetectorTypes = []
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsAirPlayForMediaPlayback = false
        config.allowsPictureInPictureMediaPlayback = false
        config.allowsInlineMediaPlayback = true
        return config
    }

    static func makeWebView(frame: CGRect, controller: WKUserContentController) -> WKWebView {
        let webView = WKWebView(frame: frame, configuration: configuration(controller: controller))
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }
}

enum WebRenderError: Error, Equatable {
    /// Mermaid rejected the source; the message is Mermaid's own.
    case mermaid(String)
    /// The job did not finish in time.
    case timedOut
    /// WebKit could not be set up, the page went away, or the result was unusable.
    case unavailable
}

/// The navigation policy of a sandboxed view: one expected load of an `about:`
/// document in the main frame, nothing else. `allowsJavaScript` is that load's
/// content-JavaScript setting (false everywhere but the Mermaid page). Reports
/// the end of the expected load to whoever awaits it.
@MainActor
final class SandboxNavigationGuard: NSObject, WKNavigationDelegate {
    let allowsJavaScript: Bool
    /// The web content process died: the page is gone.
    var onTerminate: (() -> Void)?

    private var expectingLoad = false
    private var navigation: WKNavigation?
    private var continuation: CheckedContinuation<Void, Error>?

    init(allowsJavaScript: Bool) {
        self.allowsJavaScript = allowsJavaScript
    }

    /// Load `html` as the view's one document and wait until it has loaded.
    func load(_ html: String, in webView: WKWebView) async throws {
        finish(.failure(WebRenderError.unavailable))
        expectingLoad = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.navigation = webView.loadHTMLString(html, baseURL: nil)
            if self.navigation == nil { self.finish(.failure(WebRenderError.unavailable)) }
        }
    }

    /// Load `html` without waiting (the full-screen viewers).
    func show(_ html: String, in webView: WKWebView) {
        finish(.failure(WebRenderError.unavailable))
        expectingLoad = true
        navigation = webView.loadHTMLString(html, baseURL: nil)
    }

    /// Give up on the expected load: whoever awaits it gets `.unavailable`.
    func cancel() {
        expectingLoad = false
        finish(.failure(WebRenderError.unavailable))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        if expectingLoad, isMainFrame, scheme == nil || scheme == "about" {
            expectingLoad = false
            preferences.allowsContentJavaScript = allowsJavaScript
            decisionHandler(.allow, preferences)
        } else {
            preferences.allowsContentJavaScript = false
            decisionHandler(.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        expectingLoad = false
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        expectingLoad = false
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard navigation === self.navigation else { return }
        expectingLoad = false
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        expectingLoad = false
        finish(.failure(WebRenderError.unavailable))
        onTerminate?()
    }
}

// MARK: - Live viewer

/// A live, sandboxed web view showing one document — the full-screen diagram
/// and HTML viewers. Content JavaScript is off, every load but `about:`/
/// `data:`/`blob:` is blocked, and no navigation leaves the document; scrolling,
/// pinch zoom and `<details>` work without script.
struct SandboxedWebView: UIViewRepresentable {
    let html: String
    /// Behind the document while it loads (and wherever it is transparent).
    var background: UIColor = .clear

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = SandboxedWebView.make(coordinator: context.coordinator)
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        context.coordinator.show(html, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        context.coordinator.show(html, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop(webView)
    }

    @MainActor
    private static func make(coordinator: Coordinator) -> WKWebView {
        let webView = WebSandbox.makeWebView(frame: .zero, controller: coordinator.controller)
        webView.navigationDelegate = coordinator.navigation
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        return webView
    }

    @MainActor
    final class Coordinator {
        let controller = WKUserContentController()
        let navigation = SandboxNavigationGuard(allowsJavaScript: false)
        private var shown: String?
        private var rulesInstalled = false
        private var pending: Task<Void, Never>?

        func show(_ html: String, in webView: WKWebView) {
            guard html != shown else { return }
            shown = html
            pending?.cancel()
            pending = Task { [weak self, weak webView] in
                // Nothing loads before the rule list is in place.
                guard let rules = try? await WebSandbox.blockingRules(),
                      !Task.isCancelled, let self, let webView else { return }
                if !self.rulesInstalled {
                    self.controller.add(rules)
                    self.rulesInstalled = true
                }
                self.navigation.show(html, in: webView)
            }
        }

        func stop(_ webView: WKWebView) {
            pending?.cancel()
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
    }
}
