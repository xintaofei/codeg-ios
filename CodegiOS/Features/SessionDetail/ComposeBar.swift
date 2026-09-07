import SwiftUI
import PhotosUI

/// The pinned bottom compose bar. A leading "+" sits to the left of a growing
/// multiline field; a send button sits on the right, and becomes Stop while a
/// turn streams. Sessions whose agent can take a message mid-turn get a second
/// send beside Stop, with a line above the field saying which of the two things
/// it does — insert into the running turn, or leave a note for the agent's next
/// check. Attached-image thumbnails appear above the field. The "agent is
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
    let onAddAttachments: ([Attachment]) -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onNotice: (String) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    /// How a message typed while the reply streams would reach the agent, or nil
    /// when this session has no channel for one — the bar then keeps its historic
    /// Stop-only form. Never inferred here: the view model reads it off the
    /// connection's attach snapshot.
    let midTurnChannel: SessionDetailViewModel.MidTurnChannel?
    /// A mid-turn message is in flight; the button greys out until it settles.
    let isSendingMidTurn: Bool
    let onSendMidTurn: () -> Void
    let onDismissNotice: () -> Void
    /// Backs the "+" menu's text-insert pickers (quick messages / experts / commands).
    let insertModel: ComposeInsertModel

    @FocusState private var focused: Bool
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
    private var hasDraft: Bool {
        hasText || !attachments.isEmpty
    }
    private var canSend: Bool {
        hasDraft && !isInFlight
    }
    /// The mid-turn send greys out with nothing to send, exactly like Send does,
    /// rather than appearing and disappearing as the user types.
    private var canSendMidTurn: Bool {
        hasDraft && !isSendingMidTurn
    }
    private var remainingSlots: Int {
        max(0, AttachmentPrep.maxCount - attachments.count)
    }

    /// What sending right now would actually do, said before the tap. The two
    /// channels promise different things and the composer must not blur them; a
    /// draft carrying images promises neither, because it waits for the turn.
    ///
    /// Shown from the moment the user engages the field, which is also the only
    /// way to reach a sendable draft — so the button is never actionable without
    /// its explanation on screen, and an idle streaming turn keeps its layout.
    private var midTurnHint: LocalizedStringKey? {
        guard isInFlight, focused || hasDraft, let channel = midTurnChannel else { return nil }
        guard attachments.isEmpty else {
            return "Images can't join a running turn. Sending waits for the reply to finish."
        }
        return channel.composerHint
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

            if let hint = midTurnHint {
                MidTurnHint(text: hint)
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    addButton
                    TextField("Message", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(1...6)
                        // Match the transcript body so the text you type reads at
                        // the same size as the reply it produces (was `.callout`,
                        // visibly smaller than the messages).
                        .font(Theme.Typography.messageBody)
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Theme.accent)
                        .focused($focused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
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
        .animation(Theme.Motion.expand, value: notice)
        .animation(Theme.Motion.expand, value: attachments)
        // The mid-turn affordance arrives with the attach snapshot, which can land
        // after the turn has started — fade it in rather than popping it in.
        .animation(Theme.Motion.expand, value: midTurnChannel)
        // Width + keyboard-gap shift on focus change, kept just slightly slower
        // than the keyboard's own animation so the bar settles into place.
        .animation(.snappy(duration: 0.26), value: focused)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: sendHaptic)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var addButton: some View {
        Menu {
            // Attach images. Disabled per-item when the attachment budget is full,
            // so the insert actions below stay reachable.
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
            // Stop keeps its place and its role; the mid-turn send joins it only
            // on sessions that actually have somewhere to put the message, so a
            // channel-less session stays pixel-identical to before.
            HStack(spacing: 8) {
                stopButton
                if let channel = midTurnChannel {
                    midTurnSendButton(channel)
                }
            }
        } else {
            sendButton
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.danger)
        .clipShape(Circle())
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Stop")
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
        .clipShape(Circle())
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.5)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Send")
    }

    /// Send into the running turn. Same shape as Send, because it is a send —
    /// the hint above the field carries what makes it different, and the
    /// accessibility label spells it out per channel.
    private func midTurnSendButton(_ channel: SessionDetailViewModel.MidTurnChannel) -> some View {
        Button(action: sendMidTurn) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
        .clipShape(Circle())
        .disabled(!canSendMidTurn)
        .opacity(canSendMidTurn ? 1 : 0.5)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel(Text(midTurnLabel(channel)))
    }

    /// The action's name for the draft as it stands: one with images is queued
    /// for the end of the turn rather than delivered into it, so the label must
    /// not claim to insert anything.
    private func midTurnLabel(_ channel: SessionDetailViewModel.MidTurnChannel) -> LocalizedStringKey {
        attachments.isEmpty ? channel.sendLabel : "Send when the current reply finishes"
    }

    private func send() {
        guard canSend else { return }
        sendHaptic &+= 1
        onSend()
    }

    private func sendMidTurn() {
        guard canSendMidTurn else { return }
        sendHaptic &+= 1
        onSendMidTurn()
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

private extension SessionDetailViewModel.MidTurnChannel {
    /// What a message sent right now would do, in the user's terms. The native
    /// push lands in the reply the agent is writing; the pull tool leaves a note
    /// it collects whenever it next looks. Promising the first on a pull session
    /// would be a lie, so the copy is keyed on the channel, never shared.
    var composerHint: LocalizedStringKey {
        switch self {
        case .native: return "Messages you send now go into the current turn."
        case .pull: return "Messages you send now wait for the agent's next check."
        }
    }

    /// The action's own name, for VoiceOver and the button's label.
    var sendLabel: LocalizedStringKey {
        switch self {
        case .native: return "Send into the current turn"
        case .pull: return "Send a note for the next check"
        }
    }
}

/// A quiet line above the field explaining what sending during a reply does,
/// shown from the moment the user engages the composer — so the extra button
/// beside Stop is never actionable without its explanation on screen.
private struct MidTurnHint: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal")
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 14)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
