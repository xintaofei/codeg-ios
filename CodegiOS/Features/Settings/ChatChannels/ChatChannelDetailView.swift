import SwiftUI
import Observation

/// Channel detail: enable toggle, connect / disconnect / test (or WeChat QR),
/// token status, config summary, and a recent message log. Editing the channel
/// reuses ``ChatChannelEditorSheet``. The list is told to reload only after a
/// mutation actually succeeds (the model owns that callback, so there's no
/// optimistic race against an in-flight write).
struct ChatChannelDetailView: View {
    @State private var model: ChatChannelDetailModel
    let client: CodegClient?
    @State private var showEdit = false
    @State private var showQR = false
    @State private var confirmRemoveToken = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(channel: ChatChannelInfo, client: CodegClient?, onChanged: @escaping () -> Void) {
        _model = State(initialValue: ChatChannelDetailModel(channel: channel, client: client, onChanged: onChanged))
        self.client = client
    }

    private var channel: ChatChannelInfo { model.channel }

    var body: some View {
        ZStack {
            CodegBackground()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    statusSection
                    actionsSection
                    configSection
                    if channel.channelType.secretLabel != nil { tokenSection }
                    messagesSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }.tint(Theme.accent)
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .task { await model.load() }
        .sheet(isPresented: $showEdit) {
            ChatChannelEditorSheet(editing: channel, client: client) { _, _, _, _, _, _, _ in
            } onUpdate: { body, token in
                try await model.update(body, token: token)
            }
        }
        .sheet(isPresented: $showQR) {
            WeixinQRView(channelId: channel.id, client: client) {
                Task { await model.qrConnected() }
            }
        }
        .confirmationDialog("Remove Token", isPresented: $confirmRemoveToken, titleVisibility: .visible) {
            Button("Remove Token", role: .destructive) { Task { await model.removeToken() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The channel won’t be able to connect until a new token is set.")
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK", role: .cancel) { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    // MARK: - Sections

    private var header: some View {
        GlassCard {
            HStack(spacing: 12) {
                ChannelTypeAvatar(type: channel.channelType, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name).font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Circle().fill(model.status.tint).frame(width: 7, height: 7)
                        Text(model.status.label).font(.caption).foregroundStyle(Theme.textSecondary)
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text(channel.channelType.displayName).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var statusSection: some View {
        EditorSection(title: "Status") {
            HStack {
                Text("Enabled").foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { channel.enabled }, set: { model.setEnabled($0) }))
                    .labelsHidden().tint(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            if channel.dailyReportEnabled, let time = channel.dailyReportTime {
                Divider().overlay(Theme.hairline)
                HStack {
                    Text("Daily report").foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    Text(time).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        EditorSection(title: "Connection") {
            VStack(spacing: 10) {
                if channel.channelType == .weixin {
                    actionButton("Scan QR to Connect", icon: "qrcode", role: nil) { showQR = true }
                } else if model.status == .connected {
                    actionButton("Disconnect", icon: "bolt.slash", role: .destructive) { Task { await model.disconnect() } }
                } else {
                    actionButton("Connect", icon: "bolt.fill", role: nil) { Task { await model.connect() } }
                }
                actionButton("Send Test Message", icon: "paperplane", role: nil) { Task { await model.test() } }
                    .disabled(model.status != .connected)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .overlay(alignment: .topTrailing) {
                if model.busy { ProgressView().controlSize(.small).tint(Theme.accent).padding(14) }
            }
        }
    }

    private func actionButton(_ title: LocalizedStringKey, icon: String, role: ButtonRole?, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .codegGlassButtonStyle()
        .tint(role == .destructive ? Theme.danger : Theme.accent)
        .disabled(model.busy)
    }

    private var configSection: some View {
        EditorSection(title: "Configuration") {
            HStack(alignment: .top) {
                Text("Config").foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 12)
                Text(ChannelConfig.parse(channel.configJson).summary(type: channel.channelType))
                    .font(.mono(13))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    private var tokenSection: some View {
        EditorSection(title: "Token") {
            HStack {
                Image(systemName: model.hasToken ? "key.fill" : "key")
                    .foregroundStyle(model.hasToken ? Theme.accent : Theme.textTertiary)
                Text(model.hasToken ? "\(channel.channelType.secretLabel ?? "Token") is set" : "No token set")
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if model.hasToken {
                    Button("Remove", role: .destructive) { confirmRemoveToken = true }
                        .font(.subheadline)
                        .tint(Theme.danger)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        EditorSection(title: "Recent Messages") {
            if model.messages.isEmpty {
                Text("No messages yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
            } else {
                ForEach(Array(model.messages.prefix(20).enumerated()), id: \.element.id) { index, msg in
                    if index > 0 { Divider().overlay(Theme.hairline) }
                    MessageLogRow(message: msg)
                }
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .codegGlassEffect(tint: Theme.accent.opacity(0.18), in: Capsule())
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { model.toast = nil }
                }
        }
    }
}

private struct MessageLogRow: View {
    let message: ChatChannelMessageLog

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.isInbound ? "arrow.down.left" : "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.failed ? Theme.danger : Theme.textSecondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.contentPreview.isEmpty ? "(\(message.messageType))" : message.contentPreview)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if message.failed, let detail = message.errorDetail, !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(Theme.danger).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// Loads + drives a single channel's detail: live status (with a short connect
/// poll), recent messages, token presence, and the enable toggle (coalescing
/// serial sender so rapid flips can't land out of order). `onChanged` reloads the
/// parent list and is called only after a mutation succeeds.
@MainActor
@Observable
final class ChatChannelDetailModel {
    private(set) var channel: ChatChannelInfo
    private(set) var status: ChannelConnectionStatus = .disconnected
    private(set) var messages: [ChatChannelMessageLog] = []
    private(set) var hasToken = false
    var busy = false
    var toast: String?
    var actionError: String?

    private let client: CodegClient?
    private let onChanged: () -> Void

    init(channel: ChatChannelInfo, client: CodegClient?, onChanged: @escaping () -> Void) {
        self.channel = channel
        self.client = client
        self.onChanged = onChanged
    }

    func load() async {
        await refreshStatus()
        await refreshMessages()
        hasToken = (try? await client?.chatChannelHasToken(channelId: channel.id)) ?? false
    }

    func refreshStatus() async {
        guard let client, let all = try? await client.chatChannelStatus() else { return }
        if let mine = all.first(where: { $0.channelId == channel.id }) { status = mine.status }
    }

    func refreshMessages() async {
        guard let client else { return }
        messages = (try? await client.listChatChannelMessages(channelId: channel.id, limit: 50)) ?? []
    }

    // MARK: - Connection actions

    func connect() async {
        // Only poll + notify the list when the connect actually succeeded.
        guard await perform({ try await $0.connectChatChannel(id: self.channel.id) }, note: "Connecting…") else { return }
        await pollUntilSettled()
        onChanged()   // status changed → refresh the list's status dots
    }

    func disconnect() async {
        if await perform({ try await $0.disconnectChatChannel(id: self.channel.id) }, note: "Disconnected.") {
            onChanged()
        }
    }

    func test() async {
        // A test message doesn't change list-visible state, so no onChanged.
        _ = await perform({ try await $0.testChatChannel(id: self.channel.id) }, note: "Test message sent.")
    }

    @discardableResult
    private func perform(_ op: (CodegClient) async throws -> Void, note: String) async -> Bool {
        guard let client else { return false }
        busy = true
        defer { busy = false }
        do {
            try await op(client)
            toast = note
            await refreshStatus()
            await refreshMessages()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    /// After a connect, poll a few times while the status is still "connecting".
    private func pollUntilSettled() async {
        for _ in 0..<6 {
            if status != .connecting { return }
            try? await Task.sleep(for: .seconds(1.5))
            await refreshStatus()
        }
    }

    /// Called by the WeChat QR sheet once the login is confirmed.
    func qrConnected() async {
        await load()
        onChanged()
    }

    // MARK: - Token

    func removeToken() async {
        guard let client else { return }
        do {
            try await client.deleteChatChannelToken(channelId: channel.id)
            hasToken = false
            toast = "Token removed."
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Edit (from the editor sheet)

    func update(_ body: UpdateChatChannelBody, token: String?) async throws {
        guard let client else { return }
        let updated = try await client.updateChatChannel(body)
        channel = updated
        if let token, !token.isEmpty {
            try await client.saveChatChannelToken(channelId: channel.id, token: token)
            hasToken = true
        }
        onChanged()
    }

    // MARK: - Enable toggle (coalescing serial sender)

    private var enabledSaving = false
    private var enabledPending: Bool?

    func setEnabled(_ on: Bool) {
        channel = channel.with(enabled: on)   // optimistic
        enabledPending = on
        Task { await drainEnabled() }
    }

    private func drainEnabled() async {
        guard !enabledSaving, let client else { return }
        enabledSaving = true
        defer { enabledSaving = false }
        while let target = enabledPending {
            enabledPending = nil
            do {
                var body = UpdateChatChannelBody(id: channel.id)
                body.enabled = target
                let updated = try await client.updateChatChannel(body)
                channel = updated
                onChanged()
            } catch {
                actionError = error.localizedDescription
                // Reconcile to server truth.
                if let fresh = try? await client.listChatChannels().first(where: { $0.id == channel.id }) {
                    channel = fresh
                }
                onChanged()
                return
            }
        }
    }
}
