import SwiftUI

/// Add / Edit Server sheet. Refined grouped-glass sections with clear field
/// labels, an inline Test Connection probe, and a Save action gated on
/// validation. On save it calls back with the persisted profile so the caller
/// can select it.
struct ServerEditorSheet: View {
    let store: ServerStore
    /// Called after a successful save with the resulting profile.
    let onSaved: (ServerProfile) -> Void

    @State private var model: ServerEditorModel
    @State private var saveError: LocalizedStringKey?
    @State private var showScanner = false
    @State private var scanError: LocalizedStringKey?
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable { case name, url, token }

    init(
        store: ServerStore,
        editing: ServerProfile? = nil,
        hasExistingToken: Bool = false,
        onSaved: @escaping (ServerProfile) -> Void
    ) {
        self.store = store
        self.onSaved = onSaved
        _model = State(initialValue: ServerEditorModel(
            editing: editing,
            hasExistingToken: hasExistingToken,
            // Resolve the stored token lazily so Test Connection can fall back to
            // it when the field is left blank, without holding the secret.
            resolveExistingToken: { editing.flatMap { store.token(for: $0) } }
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        connectionSection
                        authSection
                        testSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .tint(Theme.accent)
                        .disabled(!model.canSave)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerView { code in handleScanned(code) }
        }
        .alert("Couldn’t Save Server", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert("Couldn’t Read QR Code", isPresented: Binding(
            get: { scanError != nil },
            set: { if !$0 { scanError = nil } }
        )) {
            Button("OK", role: .cancel) { scanError = nil }
        } message: {
            Text(scanError ?? "")
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        EditorSection(title: "Connection") {
            FieldRow(label: "Name") {
                TextField("My codeg server", text: $model.name)
                    .textContentType(.name)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .name)
                    .onSubmit { focusedField = .url }
                    .onChange(of: model.name) { _, _ in model.fieldsChanged() }
            }

            Divider().overlay(Theme.hairline)

            FieldRow(label: "Server URL") {
                HStack(spacing: 10) {
                    TextField("http://192.168.1.10:3080", text: $model.urlString)
                        .font(.mono(15))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textContentType(.URL)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .url)
                        .onSubmit { focusedField = .token }
                        .onChange(of: model.urlString) { _, _ in model.fieldsChanged() }
                        .frame(maxWidth: .infinity)

                    // Scan codeg's "show QR" code to fill the address.
                    Button {
                        focusedField = nil
                        showScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scan QR code")
                }
            }
        }
    }

    private var authSection: some View {
        EditorSection(
            title: "Authentication",
            footer: model.authFooter
        ) {
            FieldRow(label: "Token") {
                SecureField(model.tokenPlaceholder, text: $model.token)
                    .font(.mono(15))
                    .textContentType(.password)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .token)
                    .onSubmit { focusedField = nil }
                    .onChange(of: model.token) { _, _ in model.fieldsChanged() }
            }
        }
    }

    private var testSection: some View {
        VStack(spacing: 12) {
            Button {
                focusedField = nil
                Task { await model.testConnection() }
            } label: {
                HStack(spacing: 8) {
                    if model.isTesting {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Text("Test Connection").fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .codegGlassButtonStyle()
            .tint(Theme.accent)
            .disabled(model.isTesting || !model.canTest)

            if let result = model.testResult {
                TestResultRow(result: result)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: model.testResult)
    }

    // MARK: - Actions

    private func save() {
        guard model.canSave, let saved = saveProfile() else { return }
        onSaved(saved)
        dismiss()
    }

    /// Fill the address from a scanned QR payload, or surface an error if it
    /// isn't a server address. The token still has to be entered by hand (codeg's
    /// QR carries only the URL).
    private func handleScanned(_ code: String) {
        if !model.applyScanned(code) {
            scanError = "That QR code isn’t a codeg server address. Make sure you’re scanning the server URL QR from codeg."
        }
    }

    /// Persist via the store and return the resulting profile. Stores the
    /// normalized URL (so the profile is always usable) and the trimmed token.
    /// Returns `nil` and raises an alert (without dismissing) if secure token
    /// storage failed, so the sheet never reports a save that didn't happen.
    private func saveProfile() -> ServerProfile? {
        let name = model.trimmedName
        let urlString = model.urlStringForSave

        if let existing = model.editing {
            var updated = existing
            updated.name = name
            updated.urlString = urlString
            // Pass the token only if the user re-entered one; nil keeps the
            // stored secret untouched.
            guard store.update(updated, token: model.tokenForSave) else {
                saveError = tokenSaveFailureMessage
                return nil
            }
            return updated
        } else {
            // canSave guarantees a non-empty trimmed token here.
            guard let profile = store.add(name: name, urlString: urlString, token: model.trimmedToken) else {
                saveError = tokenSaveFailureMessage
                return nil
            }
            return profile
        }
    }

    private var tokenSaveFailureMessage: LocalizedStringKey {
        "The token couldn’t be saved to the Keychain. Please try again."
    }
}

// MARK: - Building blocks

/// Inline success / failure feedback for the Test Connection probe.
private struct TestResultRow: View {
    let result: ServerEditorModel.TestResult

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            text
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: tint.opacity(0.35))
    }

    private var symbol: String {
        switch result {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch result {
        case .success: Theme.accent
        case .failure: Theme.danger
        }
    }

    private var text: Text {
        switch result {
        case .success(let version): Text("Connected · v\(version)")
        case .failure(let message): Text(verbatim: message)
        }
    }
}
