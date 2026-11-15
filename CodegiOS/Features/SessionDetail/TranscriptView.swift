import SwiftUI

// MARK: - Scroll action (environment)

/// A scroll capability the transcript publishes into the environment so any
/// descendant (an assistant reply's "scroll to question" button) can move the
/// viewport without threading the `ScrollViewProxy` down by hand.
struct TranscriptScrollAction {
    let perform: (String, UnitPoint) -> Void
    func callAsFunction(_ id: String, anchor: UnitPoint = .top) { perform(id, anchor) }
}

private struct TranscriptScrollKey: EnvironmentKey {
    static let defaultValue = TranscriptScrollAction { _, _ in }
}

/// Told by a block that grows on its own after it is first laid out — a
/// diagram, an HTML preview or an image that finished rendering or loading —
/// so a reader parked at the bottom stays there. Only a render landing calls
/// it, never the reader's own toggles (Show all, Code / Preview): those keep
/// the place the reader is looking at.
struct TranscriptGrowthAction {
    let perform: () -> Void
    func callAsFunction() { perform() }
}

private struct TranscriptGrowthKey: EnvironmentKey {
    static let defaultValue = TranscriptGrowthAction {}
}

extension EnvironmentValues {
    var transcriptScroll: TranscriptScrollAction {
        get { self[TranscriptScrollKey.self] }
        set { self[TranscriptScrollKey.self] = newValue }
    }

    var transcriptContentGrew: TranscriptGrowthAction {
        get { self[TranscriptGrowthKey.self] }
        set { self[TranscriptGrowthKey.self] = newValue }
    }
}

// MARK: - Transcript

/// The scrollable transcript, rendered as a **vertical timeline**: a continuous
/// rail runs top-to-bottom and every event — each user message, reasoning block,
/// tool call, tool group, assistant text segment, and system note — is a node on
/// it (`TranscriptTimeline.buildPersisted` flattens persisted + optimistic pending
/// turns and `buildLive` the live streaming turn, into `[TimelineNode]`). An
/// optional leading `header` scrolls away above the first node.
///
/// Backed by `List` (UICollectionView-backed) so it recycles cells and only
/// realizes on-screen rows — the iOS-native counterpart to the web client's
/// `virtua` windowing — which suits the timeline well (many small per-part rows).
/// `.defaultScrollAnchor(.bottom)` puts the first paint at the newest node.
///
/// To keep opening a very long session fast, only a **window** of the most recent
/// turns is built and rendered initially; older turns are revealed as the user
/// scrolls up (see the windowing section below). This bounds the on-open work —
/// decode aside, both node construction and the initial `List` layout become
/// O(window) rather than O(history).
struct TranscriptView<Header: View>: View {
    let turns: [MessageTurn]
    let pendingUserTurns: [MessageTurn]
    let liveTurn: LiveTurn?
    /// When the live turn was rebuilt from a reattach snapshot, it is the
    /// authoritative complete in-flight reply; the persisted partial copy the
    /// agent is concurrently writing into `turns` is hidden so it isn't doubled.
    var liveOwnsInFlightReply: Bool = false
    /// The user turn that opened the round the server says is running right now.
    /// Scopes which persisted tool calls may render as running — without it a
    /// cross-client reader shows a settled ✓ for a call that is still working,
    /// and an orphan left by an interrupted round spins forever.
    var inFlightUserTurnId: String?
    /// The session's agent, for the agent-branded marker on assistant nodes.
    let agent: AgentType
    /// Which replies are folded (the activity timeline). Applied after the
    /// memoized build, so folding never rebuilds the persisted tier.
    let replyFolds: ReplyFoldStore
    /// What the reader opened or closed in the rows, kept across the list
    /// recycling them. Read by the rows as they draw — never by the build, so
    /// it is no part of the memo's key.
    let disclosures: DisclosureStore
    /// A cheap, monotonic version of the view model's `turns`, bumped on every
    /// mutation. The persisted node tier is memoized on it (plus the window /
    /// pending / suppression signals), so a streamed token — which re-runs this
    /// view via `scrollTick` — no longer rebuilds and re-hashes the whole visible
    /// transcript to follow the scroll.
    let turnsVersion: Int
    /// Claude's out-of-turn turns not yet in `turns` (``BackgroundOverlays``),
    /// drawn after the server's, among the rounds folded in locally.
    var backgroundTurns: [BackgroundOverlayEntry] = []
    var backgroundTurnsVersion = 0
    /// Where the rounds the screen folded into `turns` itself begin.
    var localTurnsStart: Int?
    /// Bumped on streamed content growth; the transcript follows it ONLY while
    /// pinned to the bottom.
    let scrollTick: Int
    /// Bumped on the user's own send / initial load; forces a re-pin regardless
    /// of the current scroll position.
    let stickTick: Int
    /// The server holds older history above `turns[0]` — `turns` is a *window*
    /// of the transcript, not all of it (0.24+). Scrolling past the top of what
    /// is loaded fetches the next page instead of stopping.
    var hasOlderTurns: Bool = false
    /// A page of older history is in flight.
    var isLoadingOlderTurns: Bool = false
    /// Fetch one page of older history. Called once the local reveal window has
    /// exposed every loaded turn and the server still has more.
    var onLoadOlderTurns: () -> Void = {}
    /// Reports whether the viewport is parked at the bottom. The owning view uses
    /// it to show/hide the floating "jump to latest" button (which lives above the
    /// compose bar, not here, so it is reliably tappable).
    let onPinnedChange: (Bool) -> Void
    /// Bumped when `turns` was replaced by a SHORTER history (a fork cut it
    /// back). The reveal window below is an absolute index into `turns`, which
    /// would then point past the end and show nothing — so it starts over at
    /// the tail.
    var resetToken: Int = 0
    /// A message to bring to the top of the screen (the message navigator).
    /// The model has already paged in the history down to it; the reveal
    /// window here is widened to include it before scrolling.
    var jumpRequest: TranscriptJumpRequest? = nil
    /// Scrolls with the content as the first element (header above the first
    /// node). Kept generic so the transcript stays agnostic of the header's type.
    @ViewBuilder var header: () -> Header

    private let bottomAnchor = "transcript-bottom-anchor"

    /// Whether the viewport is parked at (or near) the bottom. Drives the
    /// auto-follow (only follow streamed tokens when true). Starts true so a fresh
    /// open follows.
    @State private var stuckToBottom = true
    /// The list's own scroll view, for moving to its bottom EDGE. Following the
    /// stream and re-pinning never scroll to a row: SwiftUI resolves a row
    /// scroll to an index when it is asked for and applies it with the next
    /// batch of row changes, and a send turned away at once removes the rows it
    /// had just added — the stale index then points past the end and UIKit
    /// throws (`scroll to an out-of-bounds item`).
    @State private var scrollBox = TranscriptScrollBox()

    // MARK: Windowing
    //
    // A very long transcript (thousands of turns) is expensive to open: the whole
    // history is decoded, every turn is flattened into nodes, and `List` lays out
    // the full set before the first frame — on a 6k-turn session that's hundreds of
    // ms of on-main work, exactly the cost the web client avoids by virtualizing.
    // So we only build + render a *window* of the most recent turns initially, and
    // load older ones when the user scrolls up. `build` + the `List` layout become
    // O(window) instead of O(history), so open time stops growing with length.
    //
    // `windowStartTurn` is the absolute index into `turns` where the window begins;
    // `nil` means "not yet expanded" → the window is anchored to the tail and
    // follows new turns. Persisted turns only grow at the end, so an absolute index
    // stays valid as the conversation advances.

    /// How many trailing turns to show on first open. Enough to fill the viewport
    /// with room to spare; small enough that layout is instant.
    private let initialTurnWindow = 50
    /// How many older turns to reveal each time the user scrolls near the top.
    private let pageTurns = 150
    /// Distance from the top (pt) at which to begin loading older turns — generous
    /// so history is ready before the user reaches the very top.
    private let loadEarlierThreshold: CGFloat = 600

    @State private var windowStartTurn: Int?
    /// Re-entrancy guard so a burst of near-top scroll events loads one page, not many.
    @State private var isLoadingEarlier = false

    // MARK: Node memoization
    //
    // `body` re-runs on every streamed token (the scroll-follow bumps `scrollTick`),
    // but the *persisted* node tier changes only when `turns` / the window / pending
    // / in-flight suppression change — never per token. Rebuilding it per token is
    // O(all visible text): `MessageRender.adaptTurn`'s value-keyed cache hashes each
    // `MessageTurn`'s full content on lookup (`MessageTurn` is content-`Hashable`).
    // So the persisted tier is memoized behind this cheap, content-free key and only
    // rebuilt when the key changes. The live tier is always rebuilt fresh (cheap,
    // and required so live tool / plan state doesn't freeze — see `buildLive`).
    //
    // The cache lives in a reference holder (a plain class) so it survives the
    // per-token re-instantiation of this struct at its fixed position, and so the
    // `nodes` accessor can update it without tripping `@State` invalidation: we
    // mutate the holder's fields, never reassign the `@State`. Safe because `body`
    // and the builders are `@MainActor`, so every access is serialized.
    private struct PersistedKey: Equatable {
        var turnsVersion: Int
        var effectiveStart: Int
        var pendingIDs: [String]
        var suppressInFlight: Bool
        // Part of the key, not just an input: it decides whether an unfinished
        // tool call renders as running, so the memo has to drop when the round
        // ends (or moves) even though the turns themselves may not have changed.
        var inFlightUserTurnId: String?
        var agent: AgentType
        var overlayVersion: Int
        var localTurnsStart: Int?
    }
    private final class PersistedMemo {
        var key: PersistedKey?
        var tier = TranscriptTimeline.PersistedTier(nodes: [], tail: nil)
        /// The thread's checks on each delegated task, as of this build —
        /// equal from one pass to the next until the tier is rebuilt.
        var delegationTasks = DelegationTaskIndex.empty
        var builds = 0
    }
    @State private var persistedMemo = PersistedMemo()
    /// What the connection knows about the rows; the fold reads its
    /// delegations (a finished one leaves a folded reply).
    @Environment(\.activityLive) private var activityLive

    /// What the rows read of the connection, with the thread's checks on
    /// each delegated task laid in (a check made replies later is still how
    /// that delegation stands).
    private var rowsLive: ActivityLive {
        var live = activityLive
        live.delegationTasks = persistedMemo.delegationTasks
        return live
    }

    /// The first turn index currently shown. When not explicitly expanded, anchors
    /// to the tail (most recent `initialTurnWindow` turns), snapped back to a
    /// user/system boundary so an assistant reply is never split and keeps its
    /// originating question in-window (jump-to-question stays correct).
    private var effectiveStart: Int {
        if let s = windowStartTurn { return min(max(0, s), turns.count) }
        guard turns.count > initialTurnWindow else { return 0 }
        return snappedStart(turns.count - initialTurnWindow)
    }

    /// Whether the window reaches the true start of the conversation (everything
    /// loaded). Only then is the scrollaway `header` shown and the rail's top capped.
    /// Two windows have to be exhausted: this view's local reveal window, and — on
    /// a 0.24+ server — the slice of the transcript the session actually holds.
    private var headLoaded: Bool { effectiveStart == 0 && !hasOlderTurns }

    /// Walk back from `desired` to the nearest non-assistant (user/system) turn so
    /// the window never starts in the middle of a merged assistant reply.
    private func snappedStart(_ desired: Int) -> Int {
        guard !turns.isEmpty else { return 0 }
        var i = min(max(0, desired), turns.count - 1)
        while i > 0, turns[i].role == .assistant { i -= 1 }
        return i
    }

    /// The flattened timeline: a memoized **persisted** tier + a fresh **live**
    /// tier. The persisted tier is expensive (it hashes every visible turn's content
    /// through `adaptTurn`'s cache), so it is reused whenever the cheap `PersistedKey`
    /// is unchanged — which is every streamed token. The live tier is rebuilt each
    /// pass (cheap; keeps live tool / plan cards updating). Rail endpoints are
    /// terminated on the *combined* list so the tail's `connectBottom` lands on the
    /// live node while a reply streams.
    /// The rows to draw, and the thread's latest goal — found BEFORE folding:
    /// a folded reply hides its goal row, but that goal is still the
    /// session's, and an earlier one must not pass for it.
    private var timeline: (nodes: [TimelineNode], currentGoalID: String?) {
        let start = effectiveStart
        let suppressInFlight = liveTurn != nil && liveOwnsInFlightReply
        let key = PersistedKey(
            turnsVersion: turnsVersion,
            effectiveStart: start,
            pendingIDs: pendingUserTurns.map(\.id),
            suppressInFlight: suppressInFlight,
            inFlightUserTurnId: inFlightUserTurnId,
            agent: agent,
            overlayVersion: backgroundTurnsVersion,
            localTurnsStart: localTurnsStart
        )

        let persisted: TranscriptTimeline.PersistedTier
        if persistedMemo.key == key {
            persisted = persistedMemo.tier
        } else {
            let window = start == 0 ? turns : Array(turns[start...])
            // Out-of-turn turns join after the server's, in wall-clock order
            // with the rounds folded in here.
            let slice = BackgroundOverlays.compose(window, localFrom: localTurnsStart.map { max(0, $0 - start) },
                                                   overlay: backgroundTurns)
            persisted = TranscriptTimeline.buildPersistedTier(
                turns: slice, pending: pendingUserTurns, agent: agent,
                suppressInFlight: suppressInFlight,
                inFlightUserTurnId: inFlightUserTurnId,
                forkPoints: true,
                heldAhead: Set(backgroundTurns.map(\.turn.id))
            )
            persistedMemo.key = key
            persistedMemo.tier = persisted
            persistedMemo.builds &+= 1
            persistedMemo.delegationTasks = persisted.delegationFold.index(version: persistedMemo.builds)
        }

        var all: [TimelineNode]
        if let liveTurn {
            // The live reply is the newest, so the current round — joined
            // onto the reply above it when nothing stands between them.
            all = TranscriptTimeline.appendingLive(liveTurn, to: persisted, agent: agent) { key in
                replyFolds.isOpen(key, isCurrent: true, completed: !liveTurn.isStreaming)
            }
        } else {
            all = persisted.nodes
        }
        // The live and transcript copies of one compaction, drawn once. On the
        // joined tiers, so never part of the memo.
        all = TranscriptTimeline.dedupeCompactions(all)
        let currentGoalID = TranscriptTimeline.latestGoalID(all)
        all = ReplyFolding.apply(all, store: replyFolds, live: rowsLive)
        // Terminate the rail at its endpoints, on the *combined* list. The top
        // terminates only when the window starts at the true beginning of the
        // conversation; otherwise the spine continues up into the not-yet-loaded
        // turns.
        if !all.isEmpty {
            if headLoaded { all[0].connectTop = false }
            all[all.count - 1].connectBottom = false
        }
        return (all, currentGoalID)
    }

    /// Reveal an older page of turns. Cheap (build + layout are O(window)); the
    /// bottom scroll anchor keeps the user's current position from jumping as rows
    /// are inserted above.
    ///
    /// Once the local window has exposed every loaded turn, the same gesture asks
    /// the *session* for another page off the server.
    private func loadEarlier() {
        guard !isLoadingEarlier, !isLoadingOlderTurns else { return }
        let cur = effectiveStart
        guard cur > 0 else {
            guard hasOlderTurns else { return }
            // Pin the local window open at the head before the page lands. The
            // incoming turns are PREPENDED, and a tail-anchored window (the `nil`
            // default) would recompute its start past them and hide the very page
            // that was just fetched. Index 0 is also the one absolute index a
            // prepend cannot invalidate.
            windowStartTurn = 0
            onLoadOlderTurns()
            return
        }
        isLoadingEarlier = true
        windowStartTurn = snappedStart(cur - pageTurns)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            isLoadingEarlier = false
        }
    }

    var body: some View {
        let (built, currentGoalID) = timeline
        let firstID = built.first?.id
        ScrollViewReader { proxy in
            List {
                // Top of the list. When the whole history is loaded, the `header`
                // scrolls above the first node (no gutter marker, standard margin).
                // While older turns are still windowed out, show a compact spinner
                // there during a load instead — the rail keeps `connectTop` so the
                // spine reads as continuing up into the not-yet-loaded history.
                if headLoaded {
                    header()
                        .modifier(TimelineRowChrome(top: 12, leading: TimelineMetrics.rowTrailingInset))
                } else if isLoadingEarlier || isLoadingOlderTurns {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .modifier(TimelineRowChrome(top: 14, leading: TimelineMetrics.rowTrailingInset))
                }

                ForEach(built) { node in
                    TimelineRailRow(
                        marker: node.marker,
                        connectTop: node.connectTop,
                        connectBottom: node.connectBottom,
                        startsGroup: node.startsGroup
                    ) {
                        NodeBody(node: node)
                    }
                    .modifier(TimelineRowChrome())
                    // The list opens at one end or the other, so between this
                    // and the bottom anchor one of them finds its scroll view.
                    .background {
                        if node.id == firstID { TranscriptScrollLocator(box: scrollBox) }
                    }
                    // Fade newly-inserted nodes in (the optimistic user bubble on
                    // send, the thinking tick, each streamed segment) instead of a
                    // hard cut. Pure opacity only — a geometric transition would
                    // seam the continuous rail. Driven by the `.animation(value:)`
                    // on the transcript in `SessionDetailView`.
                    .transition(.opacity)
                    .id(node.id)
                }

                // Zero-height anchor we scroll to (a little top inset keeps the
                // last node off the compose bar). Outside the rail (no gutter).
                Color.clear
                    .frame(height: 1)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .background(TranscriptScrollLocator(box: scrollBox))
                    .id(bottomAnchor)
            }
            .listStyle(.plain)
            .environment(\.replyFoldStore, replyFolds)
            .environment(\.activityLive, rowsLive)
            .environment(\.disclosureStore, disclosures)
            .scrollContentBackground(.hidden)
            // Let the 1pt anchor row actually be 1pt (List's default min row
            // height would otherwise pad it to ~44).
            .environment(\.defaultMinListRowHeight, 1)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .transformEnvironment(\.goalControl) { $0.currentGoalID = currentGoalID }
            // Publish a scroll capability so a reply's "scroll to question" button
            // (deep inside a row) can move the viewport to the user message.
            .environment(\.transcriptScroll, TranscriptScrollAction { id, anchor in
                // The reader asked to look elsewhere: the follow lets go, or
                // the next streamed word would pull them back down.
                letGoOfBottom()
                withAnimation(Theme.Motion.scroll) {
                    proxy.scrollTo(id, anchor: anchor)
                }
            })
            // Read when called: the block's new size is not laid out yet, so
            // this is still where the reader was before it grew.
            .environment(\.transcriptContentGrew, TranscriptGrowthAction {
                if stuckToBottom { scrollToBottom() }
            })
            // Bottom-following, from one reading of the geometry. Its action
            // runs for every scrolled pixel, so state changes only on a crossing
            // of the threshold. `contentInsets.bottom` keeps the math right
            // across keyboard / compose-bar inset changes.
            .onScrollGeometryChange(for: BottomEdge.self) { geo in
                BottomEdge(offset: geo.contentOffset.y,
                           visibleBottom: geo.containerSize.height - geo.contentInsets.bottom,
                           contentHeight: geo.contentSize.height)
            } action: { old, new in
                let readerScrolling = scrollBox.scrollView.map { $0.isTracking || $0.isDecelerating } ?? false
                switch BottomFollow.action(old: old, new: new, following: stuckToBottom,
                                           readerScrolling: readerScrolling,
                                           readerJustToggled: readerJustToggled,
                                           threshold: bottomThreshold) {
                case .none:
                    break
                case .pin:
                    pinBottomEdge()
                case .glide:
                    scrollBox.glideToBottom()
                case .follow(let following):
                    stuckToBottom = following
                    if !following { scrollBox.stopGlide() }
                    onPinnedChange(following)
                }
            }
            // Reveal older turns as the user scrolls toward the top. Mapped to a
            // Bool so `action` fires only when crossing into the near-top zone (not
            // every pixel); inserting rows above shifts the user out of the zone, so
            // it re-arms naturally for the next page on the next upward scroll.
            .onScrollGeometryChange(for: Bool.self) { geo in
                (geo.contentOffset.y + geo.contentInsets.top) < loadEarlierThreshold
            } action: { _, nearTop in
                // `!stuckToBottom` rejects the transient near-top geometry reported
                // while the list is still settling onto the bottom anchor at open —
                // otherwise a fresh open would immediately page in older history.
                if nearTop, !stuckToBottom, !headLoaded, !isLoadingEarlier, !isLoadingOlderTurns {
                    loadEarlier()
                }
            }
            // Streamed growth is followed off the layout (above); a tick that
            // changed no height finds the glide already at the end, and one
            // whose rows are measured by now starts it a frame sooner.
            .onChange(of: scrollTick) { _, _ in
                guard stuckToBottom else { return }
                scrollBox.glideToBottom()
            }
            // Force re-pin (user send / initial load / jump-to-latest tap),
            // regardless of scroll state. Routed through `scrollToBottom`, which
            // re-asserts on the next runloop: the first pass can stop short when
            // rich content (code blocks / markdown) is still measuring taller, so
            // a far jump would otherwise land above the true bottom.
            .onChange(of: stickTick) { _, _ in
                stuckToBottom = true
                onPinnedChange(true)
                scrollToBottom()
            }
            .onAppear { scrollToBottom() }
            .onChange(of: resetToken) { _, _ in windowStartTurn = nil }
            .onChange(of: jumpRequest) { _, request in
                if let request { jump(to: request, proxy: proxy) }
            }
        }
    }

    /// Put the end of the content at the bottom of what is visible of the list,
    /// at once.
    private func pinBottomEdge() {
        scrollBox.snapToBottom()
    }

    /// The reader turned to something else: stop following the stream.
    private func letGoOfBottom() {
        stuckToBottom = false
        scrollBox.stopGlide()
    }

    /// The reader opened or closed a row (or a reply) a moment ago: the growth
    /// that follows is theirs, in place, not the stream's.
    private var readerJustToggled: Bool {
        let last = max(disclosures.lastChoiceAt, replyFolds.lastChoiceAt)
        return last > 0 && ProcessInfo.processInfo.systemUptime - last < 0.6
    }

    /// Scroll to the bottom edge, then re-assert once after ~80 ms so a far
    /// jump (or a fresh load) still lands when late-measuring rich content has
    /// grown the transcript after the first pass.
    private func scrollToBottom() {
        pinBottomEdge()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            // The reader took hold of the list in the meantime: theirs now.
            if let scrollView = scrollBox.scrollView, scrollView.isTracking { return }
            pinBottomEdge()
        }
    }

    /// Slack (pt) below which the viewport counts as "at the bottom" — a few body
    /// lines, comfortably larger than one ~50ms streamed chunk's height delta so
    /// a single chunk can't flip auto-follow off.
    private let bottomThreshold: CGFloat = 80
}

/// Holds the transcript list's scroll view once a row has found it, and moves
/// it to the end of its content.
@MainActor
final class TranscriptScrollBox {
    weak var scrollView: UIScrollView?

    /// Drives the glide, one step per frame; nil when it rests.
    private var link: CADisplayLink?
    private var lastStep: CFTimeInterval = 0

    /// Time constant of the glide: each frame covers the share of the way
    /// left that this much time would — ~95% of a step's height in ~0.27 s,
    /// with no restart when the content grows again on the way (the target is
    /// read afresh every frame).
    private static let glideTau: CFTimeInterval = 0.09

    /// The offset that puts the end of the content at the bottom of what is
    /// visible of the list.
    private static func bottomOffset(_ scrollView: UIScrollView) -> CGFloat {
        let inset = scrollView.adjustedContentInset
        return max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
    }

    /// To the end, at once.
    func snapToBottom() {
        stopGlide()
        guard let scrollView else { return }
        let bottom = Self.bottomOffset(scrollView)
        guard abs(scrollView.contentOffset.y - bottom) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottom), animated: false)
    }

    /// To the end, gliding: the content grew under a reader parked there.
    /// A shrink, a distance longer than the screen (laying out every row on
    /// the way), or Reduce Motion goes at once.
    func glideToBottom() {
        guard let scrollView else { return }
        let distance = Self.bottomOffset(scrollView) - scrollView.contentOffset.y
        guard abs(distance) > 0.5 else { return }
        if distance < 0 || distance > scrollView.bounds.height || UIAccessibility.isReduceMotionEnabled {
            snapToBottom()
            return
        }
        guard link == nil else { return }
        let link = CADisplayLink(target: GlideStep(box: self), selector: #selector(GlideStep.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastStep = 0
    }

    func stopGlide() {
        link?.invalidate()
        link = nil
    }

    fileprivate func step(_ link: CADisplayLink) {
        // The reader took hold of the list: theirs now.
        guard let scrollView, !scrollView.isTracking, !scrollView.isDecelerating else {
            stopGlide()
            return
        }
        let dt = lastStep == 0 ? link.duration : min(max(link.timestamp - lastStep, 0), 0.05)
        lastStep = link.timestamp
        let y = scrollView.contentOffset.y
        let left = Self.bottomOffset(scrollView) - y
        // There (or past it: the content shrank on the way).
        if left <= 0.5 {
            if left != 0 {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y + left), animated: false)
            }
            stopGlide()
            return
        }
        // Never crawl the last few points.
        let move = max(left * (1 - exp(-dt / Self.glideTau)), min(left, 0.75))
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y + move), animated: false)
    }
}

/// The display link's target: it holds the link's owner weakly, so a glide
/// left running when the screen goes away ends itself on its next frame.
private final class GlideStep: NSObject {
    weak var box: TranscriptScrollBox?

    init(box: TranscriptScrollBox) {
        self.box = box
    }

    @MainActor @objc func step(_ link: CADisplayLink) {
        guard let box else {
            link.invalidate()
            return
        }
        box.step(link)
    }
}

/// An invisible view in a transcript row that finds the list's scroll view
/// (its nearest scrolling ancestor) and leaves it in the box.
private struct TranscriptScrollLocator: UIViewRepresentable {
    let box: TranscriptScrollBox

    func makeUIView(context: Context) -> LocatorView {
        let view = LocatorView()
        view.box = box
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: LocatorView, context: Context) {
        view.box = box
    }

    final class LocatorView: UIView {
        weak var box: TranscriptScrollBox?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, let box, box.scrollView == nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    box.scrollView = scrollView
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

/// Where the list's content ends against what is visible of it.
/// What the transcript does with one change of its scroll geometry: keep the
/// end in view, or start or stop following it.
enum BottomFollow {
    enum Action: Equatable {
        case none
        /// To the end at once: the room for the content moved.
        case pin
        /// To the end, gliding: the content grew (or shrank) under the end.
        case glide
        /// Following starts (true) or stops (false).
        case follow(Bool)
    }

    static func action(old: BottomEdge, new: BottomEdge, following: Bool, readerScrolling: Bool,
                       readerJustToggled: Bool, threshold: CGFloat) -> Action {
        // The bottom of the visible area moved — the keyboard, the running
        // chip, a status strip, or a keyboard re-layout that briefly resizes
        // the list and carries the offset along (the pinyin keyboard does this
        // as a sent message clears the field). While following and with the
        // reader's hands off the list, that is the layout moving the content,
        // not the reader: keep the newest line in view, and keep following.
        // At once — the room is already moving with the keyboard.
        if new.visibleBottom != old.visibleBottom, following, !readerScrolling {
            return new.hidden > 0.5 ? .pin : .none
        }
        // The content grew (or shrank) under a reader parked at the end: a
        // streamed word, a step, a card that unfolded on its own, the reply
        // settling. Follow it — off the layout, not off the update that caused
        // it, which runs before the new rows are measured (following there
        // always trails one update behind, and a step taller than the slack
        // unpinned the follow for good). Gliding, so a step slides into view
        // rather than the whole list jumping by its height. A row the reader
        // just opened or closed grows where they tapped it instead.
        if new.contentHeight != old.contentHeight, following, !readerScrolling, !readerJustToggled {
            return .glide
        }
        let isAtBottom = new.hidden <= threshold
        // The reader's hand on the list decides by where it leaves them, not
        // by a crossing: one taking hold mid-glide, with more than the slack
        // still below, never crosses it — and must not be pulled back down
        // by the next streamed word.
        if readerScrolling {
            return isAtBottom == following ? .none : .follow(isAtBottom)
        }
        // A scroll of the program's own (a glide's frames, a jump to a
        // message): only a crossing of the slack changes anything.
        let wasAtBottom = old.hidden <= threshold
        return isAtBottom == wasAtBottom ? .none : .follow(isAtBottom)
    }
}

struct BottomEdge: Equatable {
    var offset: CGFloat
    /// The bottom of the visible area, above the composer and anything over it.
    var visibleBottom: CGFloat
    var contentHeight: CGFloat
    /// How much of the content is hidden below the visible area.
    var hidden: CGFloat { contentHeight - (offset + visibleBottom) }
}

/// Shared chrome for a timeline row: transparent background, no separators, and
/// the timeline's leading/trailing insets (the leading one lines the gutter marker
/// up with the nav bar's leading button). Vertical insets are 0 — the per-node
/// vertical rhythm is baked into `TimelineRailRow` so the continuous rail
/// background spans the inter-node spacing (a `listRowInsets` gap would break the
/// spine). The header row passes a small `top` since it has no rail of its own.
private struct TimelineRowChrome: ViewModifier {
    var top: CGFloat = 0
    /// Leading inset. Defaults to the rail's wider inset (which lines the gutter
    /// marker up with the nav button); the marker-less header overrides it to the
    /// standard symmetric margin.
    var leading: CGFloat = TimelineMetrics.rowLeadingInset

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: top,
                leading: leading,
                bottom: 0,
                trailing: TimelineMetrics.rowTrailingInset
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Jump to a message (message navigator)

extension TranscriptView {
    /// Bring a message to the top of the screen. A message above the reveal
    /// window widens it to start there (a user turn is a round boundary, so
    /// the snap keeps it), and auto-follow lets go — the user is reading
    /// history now, not the stream.
    ///
    /// The scroll waits a beat when rows were just added, so the target row
    /// exists, and is re-asserted after ~80 ms, as the scroll to the bottom
    /// is: rich rows above it measure taller after the first pass and would
    /// push it off its place.
    fileprivate func jump(to request: TranscriptJumpRequest, proxy: ScrollViewProxy) {
        var widened = false
        if let index = turns.firstIndex(where: { $0.id == request.turnID }), index < effectiveStart {
            windowStartTurn = snappedStart(index)
            widened = true
        }
        letGoOfBottom()
        onPinnedChange(false)
        let id = request.turnID
        Task { @MainActor in
            if widened { try? await Task.sleep(for: .milliseconds(30)) }
            proxy.scrollTo(id, anchor: .top)
            try? await Task.sleep(for: .milliseconds(80))
            proxy.scrollTo(id, anchor: .top)
        }
    }
}
