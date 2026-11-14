import SwiftUI
import PhotosUI

/// The pinned bottom compose bar. A leading "+" sits to the left of a growing
/// multiline field; a send button sits on the right. While a turn streams it
/// becomes Stop — joined, once something is typed, by a send that QUEUES the
/// message for when the agent is free, and whose long-press sends it into the
/// running turn instead (when the session has a live-feedback channel).
/// Attached-image thumbnails appear above the field. The "agent is
/// working" state is shown as a node at the tail of the transcript timeline (a
/// thinking tick, a running tool, a streaming reply) — not as a status line here.
///
/// The "+" owns the attachment pickers (Photo Library / Camera / Files) because
/// `PhotosPicker` / `.fileImporter` must be hosted on a view in the bar. (The
/// agent avatar lives in the session's navigation bar, not here.)
struct ComposeBar: View {
    @Binding var text: String
    let isInFlight: Bool
    let notice: String?
    let attachments: [Attachment]
    let canAttachMore: Bool
    /// False only when the live session has positively said it takes images in
    /// neither encoding — then the Attach section is dropped rather than shown
    /// permanently disabled, since for that agent there is nothing to enable.
    /// True (the default) whenever capabilities are still unknown.
    let canAttachImages: Bool
    let onAddAttachments: ([Attachment]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onNotice: (String) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onDismissNotice: () -> Void
    /// Backs the "+" menu's text-insert pickers (quick messages / experts / commands).
    let insertModel: ComposeInsertModel
    /// The session can take a message into the running turn right now, and
    /// over which channel — the long-press offer's wording follows it, so a
    /// pull session never promises an instant insert.
    var canSteer: Bool = false
    var steerChannel: SteerChannel = .pull
    /// A steer is on its way; the mid-turn send waits for it.
    var isSteering: Bool = false
    var onSteer: () -> Void = {}
    /// The prompt the agent predicts comes next, offered as the empty field's
    /// placeholder; "Use" (or a bare hardware Tab) fills it in — never sends.
    var suggestion: String? = nil
    var onUseSuggestion: () -> Void = {}
    /// Backs the inline `/`·`$` command menu and `@` mention panel shown above
    /// the field. Nil turns both off.
    var suggestions: ComposerSuggestionModel? = nil

    @FocusState private var focused: Bool
    /// Bumped when the suggestion is taken, for its selection tick.
    @State private var suggestionHaptic = 0
    /// The field's caret / selection, read for the inline triggers and set to
    /// put the caret after an inserted suggestion.
    @State private var selection: TextSelection?
    /// Bumped on each suggestion pick, for a selection tick.
    @State private var pickTick = 0
    /// Bumped on each send tap to fire a light "sent" impact immediately (rather
    /// than waiting for the turn to start streaming).
    @State private var sendHaptic = 0
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var presentedInsert: ComposeInsertModel.Source?

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasContent: Bool {
        hasText || !attachments.isEmpty
    }
    /// Images ride only one of the two live-feedback wires, so a draft carrying
    /// them is queued whole instead.
    private var canSteerDraft: Bool {
        canSteer && hasText && attachments.isEmpty && !isSteering
    }
    private var remainingSlots: Int {
        max(0, AttachmentPrep.maxCount - attachments.count)
    }
    /// The suggestion, only while the field it would fill is empty.
    private var offeredSuggestion: String? {
        PromptSuggestionGate.offered(suggestion, draft: text, hasAttachments: !attachments.isEmpty,
                                     inFlight: isInFlight, steering: isSteering, queueEmpty: true)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let notice {
                NoticeBanner(message: notice, onDismiss: onDismissNotice)
            }

            if !attachments.isEmpty {
                AttachmentChipsView(attachments: attachments, onRemove: onRemoveAttachment)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let suggestions, let panel = suggestions.panel {
                ComposerSuggestionPanel(
                    state: panel,
                    onPick: { pickSuggestion($0, from: suggestions) },
                    onSelectTab: { suggestions.selectTab($0) }
                )
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    addButton
                    TextField("Message", text: $text, selection: $selection,
                              prompt: offeredSuggestion.map { Text(verbatim: $0) }, axis: .vertical)
                        // The inline menu's keys first: it ignores them while
                        // closed, which leaves Tab to the predicted prompt below.
                        .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab, .escape]) { press in
                            handleSuggestionKey(press)
                        }
                        .textInputAutocapitalization(.sentences)
                        // A suggestion is a placeholder, not a draft: two lines at most.
                        .lineLimit(offeredSuggestion == nil ? 1...6 : 1...2)
                        .onKeyPress(keys: [.tab], phases: .down) { press in
                            guard press.modifiers.isEmpty, offeredSuggestion != nil else { return .ignored }
                            useSuggestion()
                            return .handled
                        }
                        // Match the transcript body so the text you type reads at
                        // the same size as the reply it produces (was `.callout`,
                        // visibly smaller than the messages).
                        .font(Theme.Typography.messageBody)
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .focused($focused)
                        .padding(.horizontal, 16)
                        .padding(.trailing, offeredSuggestion == nil ? 0 : 44)
                        .padding(.vertical, 10)
                        .overlay(alignment: .trailing) {
                            if offeredSuggestion != nil { useSuggestionButton }
                        }
                        // `xl` radius clamps to a capsule while the field is one
                        // line (rhyming with the round +/send buttons) and relaxes
                        // to a rounded rect as it grows — no hard switch needed.
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                        .hairlineBorder(Theme.Radius.xl)

                    actionButton
                }
            }
        }
        // Idle, the bar floats as a narrower pill (36pt side margins) so it reads
        // as a compact resting affordance. Focusing the field (keyboard up) widens
        // it to the transcript's 16pt gutter, so typing gets the same width as the
        // messages it answers. The change animates with the focus transition below.
        .padding(.horizontal, focused ? 16 : 36)
        .padding(.top, 8)
        // Hosted in a bottom `safeAreaInset`. Keyboard DOWN: float a full
        // home-indicator inset (~34pt) above the edge; a small negative bottom
        // padding dips the idle bar lower while staying clear of the indicator
        // line. Keyboard UP: the inset rides just above the keyboard, so a positive
        // gap is required — the old negative pad tucked the bar *under* the
        // keyboard's top edge (part of it was obscured).
        .padding(.bottom, focused ? 8 : -10)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: max(1, remainingSlots),
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoItems) { _, items in handlePhotoItems(items) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in addCaptured(image) }
                .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in handleFiles(result) }
        .sheet(item: $presentedInsert) { source in
            ComposeInsertSheet(source: source, model: insertModel) { transform in
                text = transform(text)
            }
        }
        .animation(Theme.Motion.expand, value: isInFlight)
        .animation(Theme.Motion.expand, value: hasContent)
        .animation(Theme.Motion.expand, value: notice)
        .animation(Theme.Motion.expand, value: attachments)
        // Width + keyboard-gap shift on focus change, kept just slightly slower
        // than the keyboard's own animation so the bar settles into place.
        .animation(.snappy(duration: 0.26), value: focused)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: sendHaptic)
        .sensoryFeedback(.selection, trigger: suggestionHaptic)
        // The inline `/`·`$`·`@` triggers read the text before the caret.
        .onChange(of: text) { _, _ in refreshSuggestions() }
        .onChange(of: selection) { _, _ in refreshSuggestions() }
        .onChange(of: focused) { _, _ in refreshSuggestions() }
        .animation(Theme.Motion.expand, value: suggestions?.panel != nil)
        .sensoryFeedback(.selection, trigger: pickTick)
    }

    /// "Use" inside the field, while the predicted prompt is its placeholder.
    private var useSuggestionButton: some View {
        Button(action: useSuggestion) {
            Text("Use")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.accent.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
        .accessibilityLabel("Use suggested message")
        .transition(.opacity)
    }

    private func useSuggestion() {
        guard offeredSuggestion != nil else { return }
        suggestionHaptic &+= 1
        onUseSuggestion()
    }

    // MARK: - Inline suggestions

    /// Report text + caret to the suggestion model.
    private func refreshSuggestions() {
        suggestions?.update(text: text, caretUTF16: ComposerCaret.offset(of: selection, in: text), focused: focused)
    }

    private func pickSuggestion(_ row: ComposerSuggestionRow, from model: ComposerSuggestionModel) {
        guard let result = model.pick(row, in: text) else { return }
        replaceText(result.text, caretUTF16: result.caret)
    }

    private func handleSuggestionKey(_ press: KeyPress) -> KeyPress.Result {
        guard let suggestions else { return .ignored }
        switch suggestions.handleKey(press.key, shift: press.modifiers.contains(.shift),
                                     composing: TextInputComposition.isActive, text: text) {
        case .ignored:
            return .ignored
        case .handled:
            return .handled
        case .replace(let newText, let caret):
            replaceText(newText, caretUTF16: caret)
            return .handled
        }
    }

    /// Swap in the edited text, then put the caret after the insertion on the
    /// next runloop — set together, the field would apply the text change after
    /// the selection and drop it.
    private func replaceText(_ newText: String, caretUTF16: Int) {
        pickTick &+= 1
        text = newText
        DispatchQueue.main.async {
            selection = TextSelection(insertionPoint: ComposerCaret.index(utf16: caretUTF16, in: text))
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var addButton: some View {
        Menu {
            // Attach images. Disabled per-item when the attachment budget is full,
            // so the insert actions below stay reachable.
            if canAttachImages {
                Section("Attach") {
                    Button { showPhotoPicker = true } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    .disabled(!canAttachMore)
                    if isCameraAvailable {
                        Button { showCamera = true } label: {
                            Label("Camera", systemImage: "camera")
                        }
                        .disabled(!canAttachMore)
                    }
                    Button { showFileImporter = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .disabled(!canAttachMore)
                }
            }
            // Insert text: quick messages, expert mentions, slash commands.
            Section("Insert") {
                ForEach(ComposeInsertModel.Source.allCases) { source in
                    Button { presentedInsert = source } label: {
                        Label(source.title, systemImage: source.systemImage)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .clipShape(Circle())
        .tint(Theme.textSecondary)
        .accessibilityLabel("Add or insert")
    }

    @ViewBuilder
    private var actionButton: some View {
        if isInFlight {
            HStack(spacing: 8) {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.danger)
                .clipShape(Circle())
                .accessibilityLabel("Stop")
                if hasContent {
                    queueButton
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: send) {
                sendGlyph
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .clipShape(Circle())
            .disabled(!hasContent)
            .opacity(hasContent ? 1 : 0.5)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("Send")
        }
    }

    private var sendGlyph: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 16, weight: .bold))
            .frame(width: 26, height: 26)
    }

    /// Mid-turn send: a tap queues the message (what sending has always meant
    /// while the agent works); a long-press offers to send it into the turn
    /// that is running instead — the bolt is the instant insert, the clock the
    /// note that waits for the agent's next check.
    @ViewBuilder
    private var queueButton: some View {
        if canSteerDraft {
            Menu {
                Button(action: steer) {
                    Label(steerChannel == .pull ? LocalizedStringKey("Send note for next check") : LocalizedStringKey("Insert into current turn"),
                          systemImage: steerChannel == .pull ? "clock" : "bolt.fill")
                }
                Button(action: send) {
                    Label("Queue message", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            } label: {
                sendGlyph
            } primaryAction: {
                send()
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .clipShape(Circle())
            .accessibilityLabel("Queue message")
        } else {
            Button(action: send) {
                sendGlyph
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .clipShape(Circle())
            .disabled(isSteering)
            .opacity(isSteering ? 0.5 : 1)
            .accessibilityLabel("Queue message")
        }
    }

    private func send() {
        guard hasContent, !isSteering else { return }
        sendHaptic &+= 1
        onSend()
    }

    private func steer() {
        guard canSteerDraft else { return }
        sendHaptic &+= 1
        onSteer()
    }

    // MARK: - Attachment intake

    private func handlePhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let slots = remainingSlots
        let attempted = items.count
        Task { @MainActor in
            var prepared: [Attachment] = []
            for item in items.prefix(slots) {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                if let attachment = await Task.detached(priority: .userInitiated, operation: {
                    AttachmentPrep.make(fromImageData: data, name: "image")
                }).value {
                    prepared.append(attachment)
                }
            }
            // Notice first so the view model's more specific size/count notice (if
            // any) wins when it also drops some during add.
            if prepared.count < attempted { onNotice("Some images couldn't be added.") }
            if !prepared.isEmpty { onAddAttachments(prepared) }
            photoItems = []
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let slots = remainingSlots
        let attempted = urls.count
        Task { @MainActor in
            var prepared: [Attachment] = []
            for url in urls.prefix(slots) {
                if let attachment = await Task.detached(priority: .userInitiated, operation: {
                    AttachmentPrep.make(fromFile: url)
                }).value {
                    prepared.append(attachment)
                }
            }
            if prepared.count < attempted { onNotice("Some images couldn't be added.") }
            if !prepared.isEmpty { onAddAttachments(prepared) }
        }
    }

    /// Camera capture is a single image and small enough to prep inline on the
    /// main actor (avoids sending a non-Sendable `UIImage` across a task boundary).
    private func addCaptured(_ image: UIImage) {
        guard remainingSlots > 0, let attachment = AttachmentPrep.make(from: image, name: "camera") else { return }
        onAddAttachments([attachment])
    }
}

/// A dismissible non-fatal notice (e.g. "a turn is already running").
private struct NoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: Theme.accent.opacity(0.35))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}


/// Whether the focused field holds an input method's marked text: pinyin,
/// kana or hangul still being composed. SwiftUI does not expose it, so this
/// asks the first responder, which is the field whenever a key reaches it.
@MainActor
enum TextInputComposition {
    static var isActive: Bool {
        (FirstResponder.current as? UITextInput)?.markedTextRange != nil
    }
}

@MainActor
private enum FirstResponder {
    static weak var found: UIResponder?

    /// An action sent to a nil target goes to the first responder, which
    /// reports itself.
    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.codegReportFirstResponder(_:)),
                                        to: nil, from: nil, for: nil)
        let responder = found
        found = nil
        return responder
    }
}

extension UIResponder {
    @objc fileprivate func codegReportFirstResponder(_ sender: Any?) {
        FirstResponder.found = self
    }
}
