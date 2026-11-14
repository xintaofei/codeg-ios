import SwiftUI
import Observation

/// Loads and mutates custom model-provider endpoints. Create/update run from the
/// editor; `update` surfaces the server's "N running sessions affected" count as
/// a transient toast. Delete is optimistic with rollback (the server rejects
/// deletion when persisted agent settings still reference the provider — surfaced
/// via the `PROVIDER_IN_USE` message → "unlink first").
@MainActor
@Observable
final class ModelProvidersSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var items: [ModelProviderInfo] = []
    var refreshError: String?
    /// Transient confirmation (e.g. affected-sessions notice), auto-dismissed.
    var toast: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    /// Providers grouped by their agent, for the sectioned list. Sections follow
    /// the canonical `modelProviderSupported` order (Claude Code → Codex → Gemini);
    /// any unexpected agent type (the decoder maps unknown wire values to
    /// `.claudeCode`, and creation is limited to the supported set, so this is just
    /// defensive) sorts last, alphabetically by display name. Within a section,
    /// providers sort by name (case-insensitive) with `id` as a stable tiebreak.
    var grouped: [(agent: AgentType, items: [ModelProviderInfo])] {
        let order = AgentType.modelProviderSupported
        func rank(_ agent: AgentType) -> Int { order.firstIndex(of: agent) ?? order.count }
        return Dictionary(grouping: items, by: \.agentType)
            .map { entry in
                (agent: entry.key, items: entry.value.sorted { lhs, rhs in
                    let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    if byName != .orderedSame { return byName == .orderedAscending }
                    return lhs.id < rhs.id
                })
            }
            .sorted { lhs, rhs in
                let lr = rank(lhs.agent), rr = rank(rhs.agent)
                if lr != rr { return lr < rr }
                return lhs.agent.displayName.localizedCaseInsensitiveCompare(rhs.agent.displayName) == .orderedAscending
            }
    }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        if items.isEmpty { phase = .loading }
        do {
            items = try await client.listModelProviders()
            phase = .loaded
            refreshError = nil
        } catch {
            if items.isEmpty { phase = .failed(error.localizedDescription) }
            else { refreshError = error.localizedDescription }
        }
    }

    func create(name: String, apiUrl: String, apiKey: String, agentType: AgentType, model: String?) async throws {
        guard let client else { return }
        _ = try await client.createModelProvider(
            name: name, apiUrl: apiUrl, apiKey: apiKey, agentType: agentType, model: model
        )
        await load()
    }

    func update(_ body: UpdateModelProviderBody) async throws {
        guard let client else { return }
        let result = try await client.updateModelProvider(body)
        let n = result.affectedRunningSessions
        if n > 0 {
            toast = "\(n) running session\(n == 1 ? "" : "s") will use the new config after restart."
        }
        await load()
    }

    func delete(_ provider: ModelProviderInfo) async {
        guard let client else { return }
        let previous = items
        items.removeAll { $0.id == provider.id }
        do {
            try await client.deleteModelProvider(id: provider.id)
        } catch {
            items = previous
            refreshError = Self.deleteErrorMessage(error)
        }
    }

    /// Map the server's `PROVIDER_IN_USE:{names}` sentinel to a readable message.
    /// The block comes from persisted agent *settings* that reference this provider
    /// (`model_provider_id`), so the fix is to unlink it in those agents' settings —
    /// not to stop running sessions. Mirrors the web's "unlink before deleting".
    private static func deleteErrorMessage(_ error: Error) -> String {
        if case let APIError.server(_, _, message) = error,
           let range = message.range(of: "PROVIDER_IN_USE:") {
            let names = message[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if names.isEmpty {
                return String(localized: "An agent is currently using this provider. Unlink it in agent settings before deleting.")
            }
            return String(localized: "\(names) is currently using this provider. Unlink it in those agents’ settings before deleting.")
        }
        return error.localizedDescription
    }
}
