import SwiftUI

/// System settings: proxy, language, default terminal shell, and a read-only
/// update check. Each control persists on change via the model's coalescing
/// senders (get/set bindings so a programmatic reconcile can't re-trigger a save).
struct SystemSettingsView: View {
    @State private var model: SystemSettingsModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(client: CodegClient?) {
        _model = State(initialValue: SystemSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("System", compact: horizontalSizeClass == .compact)
        .overlay(alignment: .bottom) { toastView }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .task { await model.load() }
        .alert("Couldn’t Save", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK", role: .cancel) { model.saveError = nil }
        } message: {
            Text(model.saveError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingView(label: "Loading…")
        case .failed(let message):
            InlineErrorView(message: message) { Task { await model.load() } }
        case .loaded:
            ScrollView {
                VStack(spacing: 18) {
                    proxySection
                    languageSection
                    terminalSection
                    updateSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
        }
    }

    private var proxySection: some View {
        EditorSection(title: "Proxy", footer: "Route the server's outbound HTTP through a proxy.") {
            HStack {
                Text("Enabled").foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { model.proxyEnabled },
                    set: { model.proxyEnabled = $0; model.scheduleProxySave() }
                )).labelsHidden().tint(Theme.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            if model.proxyEnabled {
                Divider().overlay(Theme.hairline)
                FieldRow(label: "Proxy URL") {
                    TextField("http://127.0.0.1:7890", text: Binding(
                        get: { model.proxyUrl },
                        set: { model.proxyUrl = $0; model.scheduleProxySave() }
                    ))
                    .font(.mono(15)).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                }
            }
        }
    }

    private var languageSection: some View {
        EditorSection(title: "Language", footer: "Language for the app and chat replies.") {
            FieldRow(label: "Mode") {
                Picker("Mode", selection: Binding(
                    get: { model.languageMode },
                    set: { model.languageMode = $0; model.scheduleLanguageSave() }
                )) {
                    Text("System").tag("system")
                    Text("Manual").tag("manual")
                }
                .pickerStyle(.segmented)
            }
            if model.languageMode == "manual" {
                Divider().overlay(Theme.hairline)
                FieldRow(label: "Language") {
                    SelectField(selection: Binding(
                        get: { model.language },
                        set: { model.language = $0; model.scheduleLanguageSave() }
                    ), options: AppLocaleCatalog.options.map { SelectOption(value: $0.code, label: $0.label) })
                }
            }
        }
    }

    @ViewBuilder
    private var terminalSection: some View {
        EditorSection(title: "Terminal", footer: "Shell used for agent terminals on the server.") {
            FieldRow(label: "Default shell") {
                SelectBox(display: selectedShellLabel) {
                    Picker("Shell", selection: Binding(
                        get: { model.selectedShellId },
                        set: { newId in
                            model.selectedShellId = newId
                            // Concrete/system options can save immediately; the custom
                            // option waits until a path is entered.
                            if model.shellOptions.first(where: { $0.id == newId })?.acceptsCustomPath != true {
                                model.scheduleTerminalSave()
                            }
                        }
                    )) {
                        ForEach(model.shellOptions) { opt in
                            Text(shellLabel(opt)).tag(opt.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            if isCustomSelected {
                Divider().overlay(Theme.hairline)
                FieldRow(label: "Custom path") {
                    TextField("/bin/zsh", text: Binding(
                        get: { model.customShellPath },
                        set: { model.customShellPath = $0; model.scheduleTerminalSave() }
                    ))
                    .font(.mono(15)).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                }
                HStack(spacing: 10) {
                    Button { Task { await model.probeCustomShell() } } label: {
                        HStack(spacing: 6) {
                            if model.probing { ProgressView().controlSize(.small) }
                            Text("Test")
                        }
                    }
                    .codegGlassButtonStyle().tint(Theme.accent)
                    .disabled(model.probing || model.customShellPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let probe = model.probeResult {
                        Label(probe ? "Executable found" : "Not found", systemImage: probe ? "checkmark.circle" : "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(probe ? Color(red: 0.30, green: 0.78, blue: 0.38) : Theme.danger)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
            }
        }
    }

    private var updateSection: some View {
        EditorSection(title: "Updates") {
            Button { Task { await model.checkUpdate() } } label: {
                HStack(spacing: 8) {
                    if model.checkingUpdate { ProgressView().controlSize(.small).tint(Theme.accent) }
                    Text(model.checkingUpdate ? "Checking…" : "Check for Updates")
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(model.checkingUpdate)
            .padding(.horizontal, 16).padding(.vertical, 13)

            if let info = model.updateInfo {
                Divider().overlay(Theme.hairline)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current version \(info.currentVersion)")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    if let update = info.update {
                        Text("Update available: v\(update.version)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        if !update.body.isEmpty {
                            Text(update.body).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(4)
                        }
                    } else {
                        Label("You’re up to date.", systemImage: "checkmark.circle")
                            .font(.subheadline).foregroundStyle(Color(red: 0.30, green: 0.78, blue: 0.38))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 13)
            }
        }
    }

    private var isCustomSelected: Bool {
        model.shellOptions.first { $0.id == model.selectedShellId }?.acceptsCustomPath == true
    }

    /// The selected shell's label for the closed `SelectBox`; falls back to "—"
    /// before options load. Returns `LocalizedStringKey` so the parameterized
    /// "System default (%@)" form keeps its translation in the box.
    private var selectedShellLabel: LocalizedStringKey {
        guard let opt = model.shellOptions.first(where: { $0.id == model.selectedShellId }) else { return "—" }
        return shellLabel(opt)
    }

    private func shellLabel(_ opt: TerminalShellOption) -> LocalizedStringKey {
        if opt.id == "system" { return resolvedShellLabel }
        if opt.acceptsCustomPath { return "Custom path" }
        return LocalizedStringKey(opt.value ?? opt.id)
    }

    private var resolvedShellLabel: LocalizedStringKey {
        model.resolvedShell.isEmpty ? "System default" : "System default (\(model.resolvedShell))"
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .codegGlassEffect(tint: Theme.accent.opacity(0.18), in: Capsule())
                .padding(.horizontal, 24).padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { model.toast = nil }
                }
        }
    }
}
