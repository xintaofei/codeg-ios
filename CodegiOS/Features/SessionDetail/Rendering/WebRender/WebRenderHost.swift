import SwiftUI
import UIKit
import WebKit

/// A Mermaid diagram drawn for the transcript: the theme's SVG and, for one
/// column width and height cap, the picture shown inline.
struct MermaidRendering {
    let diagram: MermaidDiagram
    let theme: MermaidTheme
    let image: UIImage
    /// The picture's size in points: the drawn width × the capped height.
    let size: CGSize
    /// The drawn height before the cap.
    let drawnHeight: CGFloat
    /// The diagram runs on below the picture.
    var clipped: Bool { MermaidGeometry.isClipped(drawnHeight: drawnHeight, clipHeight: size.height) }
}

/// The app's one off-screen web renderer. Diagrams (and, with the HTML preview
/// on, chat HTML) are drawn by WebKit into static pictures here, so the
/// transcript itself holds no web views.
///
/// - **One job at a time.** Every job waits its turn on one serial gate;
///   identical requests share one job (`inFlight`), and results are cached
///   (`diagrams`/`images`) by content + theme + size — never by turn id.
/// - **Lazy, kept warm.** The Mermaid page is built on the first diagram: an
///   `about:` document that is handed the bundled library (~3.6 MB) once and
///   kept for every later diagram. A crashed or stuck page is thrown away and
///   rebuilt on the next job.
/// - **Bounded.** Each step has a timeout; bitmaps stay within a pixel budget.
/// - **Never mid-stream.** Callers only ask for a diagram once its fence has
///   closed (or the reply stopped streaming) — see `MarkdownFence`.
///
/// ## Hosting and capture
///
/// The pages' web views sit in a 1×1-point, clipped, non-interactive container
/// parked off-screen in the active window (`OffscreenParking`). In a window,
/// WebKit treats the page as visible, so its timers and animation frames run
/// at full speed — Mermaid's newer parsers yield with `setTimeout(0)`, which a
/// hidden page throttles to a second or more per tick. Pictures are captured
/// with `createPDF(configuration:)` for the exact page rect and rasterized
/// locally: that path paints in the web content process from the render tree,
/// whatever the view's size, window or on-screen tiles, so a diagram taller
/// than the view needs no giant (and memory-hungry) web view frame, and the
/// raster scale is ours to choose. (`takeSnapshot` in a visible window copies
/// the composited tiles instead, which only cover the view's bounds.)
@MainActor
final class WebRenderHost {
    static let shared = WebRenderHost()

    /// SVG per source + theme: 32 entries / 8 MB of text, as the web's cache.
    private let diagrams = TextResultCache<MermaidDiagram>(limit: 32, maxBytes: 8 * 1024 * 1024) {
        $0.svg.utf16.count * 2
    }
    /// Inline pictures per source + theme + size. Bitmaps are far larger than
    /// the web's documents, so they get their own, cost-bounded cache (which
    /// the system also empties under memory pressure).
    private let images: NSCache<NSString, CacheBox<MermaidRendering>> = WebRenderHost.pictureCache()
    /// The last picture key drawn per SVG key, so a re-created block can show
    /// its diagram at once while it is redrawn for a new width.
    private var latestImageKey: [String: String] = [:]
    /// HTML previews per source + theme + width + covered height.
    private let htmlImages: NSCache<NSString, CacheBox<HtmlRendering>> = WebRenderHost.pictureCache()

    private var inFlight: [String: Task<MermaidRendering, Error>] = [:]
    private var htmlInFlight: [String: Task<HtmlRendering, Error>] = [:]
    private let gate = SerialGate()
    private let parking = OffscreenParking()
    private var mermaidPage: RenderPage?
    /// The HTML preview's page: content JavaScript off, one document a job.
    private var htmlPage: RenderPage?

    /// Bitmap budget of an inline picture.
    private static let inlineMaxPixels: CGFloat = 8_000_000
    /// Bitmap budget of an HTML preview (up to 12,000 points tall).
    private static let htmlMaxPixels: CGFloat = 12_000_000

    private static func pictureCache<Value>() -> NSCache<NSString, CacheBox<Value>> {
        let cache = NSCache<NSString, CacheBox<Value>>()
        cache.countLimit = 32
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }

    private static func cost(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
    }

    private init() {
        // Lives as long as the process: the observer is never removed.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.trimForMemoryWarning() }
        }
    }

    // MARK: Mermaid

    struct MermaidRequest: Hashable {
        let source: String
        let theme: MermaidTheme
        /// The column the picture fills, in points.
        let width: CGFloat
        /// The picture's height cap, in points.
        let maxHeight: CGFloat

        var diagramKey: String { WebRenderKey.mermaid(source: source, theme: theme) }
        var imageKey: String {
            WebRenderKey.mermaidImage(source: source, theme: theme, width: width, clip: maxHeight)
        }
    }

    /// The finished picture for exactly this request, if it is cached.
    func cachedMermaid(_ request: MermaidRequest) -> MermaidRendering? {
        images.object(forKey: request.imageKey as NSString)?.value
    }

    /// The last picture drawn of this source and theme at any size, if cached.
    func latestMermaid(source: String, theme: MermaidTheme) -> MermaidRendering? {
        let key = WebRenderKey.mermaid(source: source, theme: theme)
        guard let imageKey = latestImageKey[key] else { return nil }
        return images.object(forKey: imageKey as NSString)?.value
    }

    /// Draw a diagram for the transcript. Throws `.mermaid(message)` for a
    /// source Mermaid rejects; failures are not cached, so asking again retries.
    func mermaid(_ request: MermaidRequest) async throws -> MermaidRendering {
        if let hit = cachedMermaid(request) { return hit }
        let key = request.imageKey
        if let running = inFlight[key] { return try await running.value }
        let job = Task { @MainActor () async throws -> MermaidRendering in
            defer { self.inFlight[key] = nil }
            await self.gate.acquire()
            defer { self.gate.release() }
            if let hit = self.cachedMermaid(request) { return hit }
            return try await self.drawMermaid(request)
        }
        inFlight[key] = job
        return try await job.value
    }

    /// The diagram as PNG data, at three times its own size within the export
    /// budget, on a transparent background — what the web's "Download as PNG"
    /// writes.
    func mermaidPNG(_ diagram: MermaidDiagram) async throws -> Data {
        await gate.acquire()
        defer { gate.release() }
        let page = try await withTimeout(Self.warmUpTimeout, onTimeout: discardMermaidPage) {
            try await self.readyMermaidPage()
        }
        return try await withTimeout(Self.stepTimeout, onTimeout: discardMermaidPage) {
            let width = diagram.natural?.width ?? 800
            let box = try await page.stage(svg: diagram.svg, width: width, height: diagram.natural?.height ?? 0,
                                           background: "transparent")
            let scale = PixelBudget.scale(for: box, preferred: MermaidExport.pngScale,
                                          maxPixels: MermaidExport.maxPixels, maxSide: MermaidExport.maxSide)
            let image = try await page.capture(CGRect(origin: .zero, size: box), scale: scale, background: nil)
            await page.clearStage()
            guard let data = image.pngData() else { throw WebRenderError.unavailable }
            return data
        }
    }

    private func drawMermaid(_ request: MermaidRequest) async throws -> MermaidRendering {
        guard request.width > 0, request.maxHeight > 0 else { throw WebRenderError.unavailable }
        let page = try await withTimeout(Self.warmUpTimeout, onTimeout: discardMermaidPage) {
            try await self.readyMermaidPage()
        }
        let diagram: MermaidDiagram
        if let cached = diagrams[request.diagramKey] {
            diagram = cached
        } else {
            let svg = try await withTimeout(Self.stepTimeout, onTimeout: discardMermaidPage) {
                try await page.renderMermaid(source: request.source, theme: request.theme)
            }
            diagram = MermaidDiagram(svg: MermaidGeometry.stripSvgMaxWidth(svg),
                                     natural: MermaidGeometry.parseSvgSize(svg))
            diagrams.insert(diagram, for: request.diagramKey)
        }
        let rendering = try await withTimeout(Self.stepTimeout, onTimeout: discardMermaidPage) {
            try await self.picture(of: diagram, request: request, page: page)
        }
        images.setObject(CacheBox(rendering), forKey: request.imageKey as NSString,
                         cost: Self.cost(of: rendering.image))
        latestImageKey[request.diagramKey] = request.imageKey
        if latestImageKey.count > 128 { latestImageKey.removeAll() }
        return rendering
    }

    private func picture(of diagram: MermaidDiagram, request: MermaidRequest,
                         page: RenderPage) async throws -> MermaidRendering {
        let palette = RichBlockPalette(dark: request.theme.dark)
        let width = MermaidGeometry.inlineWidth(natural: diagram.natural, column: request.width)
        let height = diagram.natural.map { width * $0.height / max($0.width, 1) } ?? 0
        let box = try await page.stage(svg: diagram.svg, width: width, height: height, background: palette.css)
        let clip = MermaidGeometry.inlineClip(drawnHeight: box.height, maxHeight: request.maxHeight)
        let size = CGSize(width: box.width, height: clip)
        let scale = PixelBudget.scale(for: size, preferred: parking.displayScale, maxPixels: Self.inlineMaxPixels)
        let image = try await page.capture(CGRect(origin: .zero, size: size), scale: scale,
                                           background: palette.rgb)
        await page.clearStage()
        return MermaidRendering(diagram: diagram, theme: request.theme, image: image, size: size,
                                drawnHeight: box.height)
    }

    // MARK: Pages

    private static let warmUpTimeout: Double = 30
    private static let stepTimeout: Double = 15

    /// The Mermaid page, built (and handed the library) when there is none or
    /// the last one died.
    private func readyMermaidPage() async throws -> RenderPage {
        if let page = mermaidPage, page.isUsable {
            parking.attachIfNeeded()
            return page
        }
        mermaidPage?.discard()
        mermaidPage = nil
        let rules = try await WebSandbox.blockingRules()
        let page = RenderPage(rules: rules, allowsJavaScript: true,
                              frame: CGRect(x: 0, y: 0, width: 800, height: 600), parking: parking)
        // Owned before the first await: a timeout that fires mid-warm-up
        // discards this page rather than leaving it parked and orphaned.
        mermaidPage = page
        try await page.load(MermaidHost.pageHTML)
        let library = try await MermaidHost.libraryScript()
        try await page.evaluate(library + "\n;true")
        try await page.evaluate(MermaidHost.bootstrapScript)
        page.isWarm = true
        return page
    }

    /// The HTML page: no warm-up, each job loads its own document.
    private func readyHtmlPage() async throws -> RenderPage {
        if let page = htmlPage, page.isUsable {
            parking.attachIfNeeded()
            return page
        }
        htmlPage?.discard()
        htmlPage = nil
        let rules = try await WebSandbox.blockingRules()
        let page = RenderPage(rules: rules, allowsJavaScript: false,
                              frame: CGRect(x: 0, y: 0, width: 400, height: HtmlPreviewMetrics.placeholderHeight),
                              parking: parking)
        page.isWarm = true
        htmlPage = page
        return page
    }

    /// Run `operation`, giving up after `seconds`. A step that times out leaves
    /// its page in an unknown state: `onTimeout` throws that page away.
    private func withTimeout<T>(_ seconds: Double, onTimeout: @MainActor () -> Void,
                                _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        do {
            return try await TimeoutRace<T>.run(seconds: seconds, operation)
        } catch WebRenderError.timedOut {
            onTimeout()
            throw WebRenderError.timedOut
        }
    }

    /// Throw a page away; the next job builds it again.
    private func discardMermaidPage() {
        mermaidPage?.discard()
        mermaidPage = nil
    }

    private func discardHtmlPage() {
        htmlPage?.discard()
        htmlPage = nil
    }

    private func trimForMemoryWarning() {
        diagrams.removeAll()
        images.removeAllObjects()
        htmlImages.removeAllObjects()
        latestImageKey.removeAll()
        // A page in use is left alone; an idle one is rebuilt on demand.
        if !gate.isBusy {
            discardMermaidPage()
            discardHtmlPage()
        }
    }

    // MARK: HTML preview

    struct HtmlRequest: Hashable, Sendable {
        let source: String
        let theme: ChatHtmlTheme
        /// The column the document is laid out in, in points.
        let width: CGFloat
        /// How much of the document, from the top, the picture covers.
        let clip: CGFloat

        var key: String { WebRenderKey.html(source: source, theme: theme, width: width, clip: clip) }
    }

    func cachedHtml(_ request: HtmlRequest) -> HtmlRendering? {
        htmlImages.object(forKey: request.key as NSString)?.value
    }

    /// Lay the fence's document out at the column's width and draw (the top
    /// `clip` points of) it. Not cached on failure.
    func html(_ request: HtmlRequest) async throws -> HtmlRendering {
        if let hit = cachedHtml(request) { return hit }
        let key = request.key
        if let running = htmlInFlight[key] { return try await running.value }
        let job = Task { @MainActor () async throws -> HtmlRendering in
            defer { self.htmlInFlight[key] = nil }
            await self.gate.acquire()
            defer { self.gate.release() }
            if let hit = self.cachedHtml(request) { return hit }
            guard request.width > 0, request.clip > 0 else { throw WebRenderError.unavailable }
            let document = await Task.detached(priority: .userInitiated) {
                ChatHtmlDocument.build(source: request.source, theme: request.theme)
            }.value
            let rendering = try await self.withTimeout(Self.stepTimeout, onTimeout: self.discardHtmlPage) {
                try await self.drawHtml(document, request: request)
            }
            self.htmlImages.setObject(CacheBox(rendering), forKey: key as NSString,
                                      cost: Self.cost(of: rendering.image))
            return rendering
        }
        htmlInFlight[key] = job
        return try await job.value
    }

    private func drawHtml(_ document: String, request: HtmlRequest) async throws -> HtmlRendering {
        let page = try await readyHtmlPage()
        // The layout viewport: the column's width, the default preview height
        // (so `100vh` content measures as it would in the web's first frame).
        page.webView.frame = CGRect(x: 0, y: 0, width: request.width, height: HtmlPreviewMetrics.placeholderHeight)
        try await page.load(document)
        let measured = try await page.documentHeight()
        let height = HtmlPreviewMetrics.clamp(measured)
        let covered = min(height, request.clip)
        let size = CGSize(width: request.width, height: covered)
        let scale = PixelBudget.scale(for: size, preferred: parking.displayScale, maxPixels: Self.htmlMaxPixels)
        let image = try await page.capture(CGRect(origin: .zero, size: size), scale: scale,
                                           background: RichBlockPalette(dark: request.theme.dark).rgb)
        return HtmlRendering(image: image, width: request.width, height: height, covered: covered,
                             theme: request.theme)
    }
}

/// A chat HTML preview drawn for one column width.
struct HtmlRendering {
    let image: UIImage
    /// The column it was laid out in.
    let width: CGFloat
    /// The document's height, clamped 96–12,000.
    let height: CGFloat
    /// How much of it, from the top, the picture covers.
    let covered: CGFloat
    let theme: ChatHtmlTheme
}

private final class CacheBox<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Palette

/// The surface diagram and HTML pictures are drawn on, and the inline card
/// behind them: `Theme.bgElevated` — white in light mode, a lifted near-black
/// in dark — so a picture and its card are one color.
struct RichBlockPalette {
    let dark: Bool

    var rgb: (red: Double, green: Double, blue: Double) {
        dark ? (0.078, 0.085, 0.098) : (1, 1, 1)
    }

    /// The same color for the page's CSS.
    var css: String {
        let c = rgb
        func channel(_ v: Double) -> String { String(format: "%.2f", v * 255) }
        return "rgb(\(channel(c.red)),\(channel(c.green)),\(channel(c.blue)))"
    }

    var color: Color {
        let c = rgb
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    var uiColor: UIColor {
        let c = rgb
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    /// The card color as a dynamic SwiftUI color.
    static let card = Color(light: RichBlockPalette(dark: false).color, dark: RichBlockPalette(dark: true).color)
}

// MARK: - Page

/// One sandboxed web view of the renderer, parked off-screen.
@MainActor
final class RenderPage {
    let webView: WKWebView
    private let navigation: SandboxNavigationGuard
    private let controller: WKUserContentController
    /// The page has been loaded and set up (the Mermaid page: library run).
    var isWarm = false
    private(set) var isDead = false

    var isUsable: Bool { isWarm && !isDead }

    init(rules: WKContentRuleList, allowsJavaScript: Bool, frame: CGRect, parking: OffscreenParking) {
        let controller = WKUserContentController()
        // In place before the view exists: nothing ever loads without it.
        controller.add(rules)
        self.controller = controller
        let navigation = SandboxNavigationGuard(allowsJavaScript: allowsJavaScript)
        self.navigation = navigation
        webView = WebSandbox.makeWebView(frame: frame, controller: controller)
        webView.navigationDelegate = navigation
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        navigation.onTerminate = { [weak self] in self?.isDead = true }
        parking.park(webView)
    }

    func load(_ html: String) async throws {
        guard !isDead else { throw WebRenderError.unavailable }
        try await navigation.load(html, in: webView)
    }

    func evaluate(_ script: String) async throws {
        guard !isDead else { throw WebRenderError.unavailable }
        _ = try await webView.evaluateJavaScript(script, in: nil, contentWorld: .page)
    }

    /// Mermaid's SVG for `source`, or `.mermaid(message)`.
    func renderMermaid(source: String, theme: MermaidTheme) async throws -> String {
        guard !isDead else { throw WebRenderError.unavailable }
        let result = try await webView.callAsyncJavaScript(
            MermaidHost.renderCall,
            arguments: ["source": source, "theme": theme.name, "font": MermaidHost.fontFamily],
            in: nil, contentWorld: .page)
        guard let reply = result as? [String: Any] else { throw WebRenderError.unavailable }
        if (reply["ok"] as? Bool) == true, let svg = reply["svg"] as? String, !svg.isEmpty {
            return svg
        }
        let message = (reply["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw WebRenderError.mermaid(message)
    }

    /// Put `svg` on the stage `width` points wide (and `height` tall, or by
    /// its viewBox's ratio when 0) and return the box it takes.
    func stage(svg: String, width: CGFloat, height: CGFloat, background: String) async throws -> CGSize {
        guard !isDead else { throw WebRenderError.unavailable }
        let result = try await webView.callAsyncJavaScript(
            MermaidHost.stageCall,
            arguments: ["svg": svg, "width": Double(width), "height": Double(height), "background": background],
            in: nil, contentWorld: .page)
        guard let box = result as? [String: Any],
              let w = (box["width"] as? NSNumber)?.doubleValue,
              let h = (box["height"] as? NSNumber)?.doubleValue,
              w.isFinite, h.isFinite, w > 0, h > 0 else { throw WebRenderError.unavailable }
        return CGSize(width: w, height: h)
    }

    func clearStage() async {
        guard !isDead else { return }
        _ = try? await webView.callAsyncJavaScript(MermaidHost.clearCall, arguments: [:], in: nil,
                                                    contentWorld: .page)
    }

    /// The loaded document's height in points, measured as the web's size
    /// reporter measures it: the root's box, or the body's overflow plus its
    /// margins, whichever is taller. The script is the app's own, run in the
    /// app's world — content JavaScript stays off. Falls back to the scroll
    /// view's content size should script be unavailable.
    func documentHeight() async throws -> Double {
        guard !isDead else { throw WebRenderError.unavailable }
        if let value = try? await webView.evaluateJavaScript(Self.measureScript, in: nil, contentWorld: .defaultClient),
           let height = (value as? NSNumber)?.doubleValue {
            return height
        }
        try? await Task.sleep(for: .milliseconds(120))
        return Double(webView.scrollView.contentSize.height)
    }

    private static let measureScript = """
    (() => {
      const d = document.documentElement, b = document.body;
      if (!b) return 0;
      const root = d.getBoundingClientRect().height, box = b.getBoundingClientRect().height;
      if (root === 0 && box === 0) return 0;
      const s = getComputedStyle(b);
      return Math.ceil(Math.max(root, Math.max(b.scrollHeight, box) + (parseFloat(s.marginTop) || 0) + (parseFloat(s.marginBottom) || 0)));
    })()
    """

    /// The page's `rect` (page coordinates) as a bitmap of `scale` pixels per
    /// point. With a `background`, the bitmap is opaque on it; without, the
    /// page's own transparency is kept.
    func capture(_ rect: CGRect, scale: CGFloat,
                 background: (red: Double, green: Double, blue: Double)?) async throws -> UIImage {
        guard !isDead, rect.width > 0, rect.height > 0, scale > 0 else { throw WebRenderError.unavailable }
        let config = WKPDFConfiguration()
        config.rect = rect
        config.allowTransparentBackground = background == nil
        let data = try await webView.pdf(configuration: config)
        let size = rect.size
        let image = await Task.detached(priority: .userInitiated) {
            PDFRaster.image(from: data, size: size, scale: scale, background: background)
        }.value
        guard let image else { throw WebRenderError.unavailable }
        return image
    }

    func discard() {
        isDead = true
        // A load still being awaited ends now rather than never.
        navigation.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }
}

// MARK: - Raster

/// Draws page 1 of a PDF into a bitmap. Thread-safe.
enum PDFRaster {
    static func image(from data: Data, size: CGSize, scale: CGFloat,
                      background: (red: Double, green: Double, blue: Double)?) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0, size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = background != nil
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            if let background {
                cg.setFillColor(red: background.red, green: background.green, blue: background.blue, alpha: 1)
                cg.fill(CGRect(origin: .zero, size: size))
            }
            // PDF space runs bottom-up; the bitmap top-down.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: size.width / box.width, y: -size.height / box.height)
            cg.translateBy(x: -box.minX, y: -box.minY)
            cg.interpolationQuality = .high
            cg.drawPDFPage(page)
        }
    }
}

// MARK: - Parking

/// Keeps the renderer's web views in a window — WebKit runs a page in no
/// window as a hidden one — without showing or exposing them: a 1×1-point,
/// clipped, non-interactive, accessibility-hidden container far off-screen in
/// the active window. Moved to another window when its own leaves the
/// foreground; with no window at all the views simply wait detached.
@MainActor
final class OffscreenParking {
    private let container: UIView = {
        let view = UIView(frame: CGRect(x: -16_384, y: -16_384, width: 1, height: 1))
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.isAccessibilityElement = false
        return view
    }()

    func park(_ view: UIView) {
        if view.superview !== container { container.addSubview(view) }
        attachIfNeeded()
    }

    func attachIfNeeded() {
        if let window = container.window, window.windowScene?.activationState == .foregroundActive { return }
        guard let window = Self.activeWindow(), window !== container.window else { return }
        window.addSubview(container)
    }

    /// Pixels per point of the screen the pictures are for.
    var displayScale: CGFloat {
        let scale = (container.window ?? Self.activeWindow())?.traitCollection.displayScale ?? 0
        return scale > 0 ? scale : 3
    }

    static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let candidates = active.isEmpty ? scenes : active
        for scene in candidates {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        return candidates.lazy.flatMap { $0.windows }.first
    }
}

// MARK: - Scheduling

/// One job at a time, first come first served.
@MainActor
final class SerialGate {
    private(set) var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Races an operation against a timer. On timeout the caller resumes at once
/// with `.timedOut`; the operation is cancelled and its eventual result, if
/// any, dropped.
@MainActor
final class TimeoutRace<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    static func run(seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let race = TimeoutRace<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.continuation = continuation
            race.work = Task { @MainActor in
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            race.timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                race.work?.cancel()
                race.finish(.failure(WebRenderError.timedOut))
            }
        }
    }

    private func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(with: result)
    }
}
