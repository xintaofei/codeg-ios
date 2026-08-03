import SwiftUI
import Observation

/// Built-in expert categories in the web's fixed pipeline order, with display
/// labels — mirrors the web's `CATEGORY_SORT` (experts-settings.tsx). The catalog
/// is sorted by this rank, not alphabetically, so the list reads in workflow
/// order (Discovery → … → Meta). Unknown categories sort last (rank 99) with a
/// capitalized fallback label, so a new server-side category is never dropped.
enum ExpertCategory {
    private static let known: [String: (rank: Int, label: String)] = [
        "discovery": (1, "Discovery"),
        "planning": (2, "Planning"),
        "execution": (3, "Execution"),
        "quality": (4, "Quality"),
        "debugging": (5, "Debugging"),
        "review": (6, "Review"),
        "meta": (7, "Meta"),
    ]

    static func rank(_ key: String) -> Int { known[key]?.rank ?? 99 }

    static func label(_ key: String) -> String {
        if let label = known[key]?.label { return label }
        let cleaned = key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Other" : cleaned.capitalized
    }
}

/// Loads the built-in expert catalog (`experts_list`) plus the server's usable
/// agents (for the per-expert link matrix). Read-only at this level; linking
/// happens in `ExpertDetailModel`.
@MainActor
@Observable
final class ExpertsSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var experts: [ExpertListItem] = []
    /// Server agents (available + enabled), the columns of each expert's matrix.
    private(set) var agents: [AgentType] = []
    var refreshError: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    /// Experts grouped by category in the web's pipeline order (Discovery → … →
    /// Meta; unknown categories last, then alphabetical), each group's items by
    /// `sortOrder` then `id` (matching the web's `localeCompare` tiebreak so the
    /// order is stable). Carries the display `label` so the view needn't re-derive
    /// it per group.
    var grouped: [(category: String, label: String, items: [ExpertListItem])] {
        let byCategory = Dictionary(grouping: experts) { $0.metadata.category }
        return byCategory.keys
            .sorted { lhs, rhs in
                let (rankL, rankR) = (ExpertCategory.rank(lhs), ExpertCategory.rank(rhs))
                return rankL != rankR ? rankL < rankR : lhs < rhs
            }
            .map { key in
                let items = byCategory[key, default: []].sorted {
                    $0.metadata.sortOrder != $1.metadata.sortOrder
                        ? $0.metadata.sortOrder < $1.metadata.sortOrder
                        : $0.id < $1.id
                }
                return (key, ExpertCategory.label(key), items)
            }
    }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        if experts.isEmpty { phase = .loading }
        do {
            experts = try await client.builtInExperts()
            // Agents are best-effort — a failure here shouldn't blank the catalog.
            if let list = try? await client.listAgents() {
                CustomAgentRegistry.shared.ingest(list)
                agents = list.filter { $0.available && $0.enabled }
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .map(\.agentType)
            }
            phase = .loaded
            refreshError = nil
        } catch {
            if experts.isEmpty { phase = .failed(error.localizedDescription) }
            else { refreshError = error.localizedDescription }
        }
    }
}
