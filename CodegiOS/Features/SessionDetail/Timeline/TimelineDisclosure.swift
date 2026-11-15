import SwiftUI

// How the timeline's disclosures remember what the reader opened across the
// list recycling their rows (``DisclosureStore``): `NodeBody` roots a scope at
// its node's id, a row that draws several of one disclosure nests a level per
// member, and each disclosure reads and writes its key through
// ``DisclosureChoice``.

private struct DisclosureStoreKey: EnvironmentKey {
    static let defaultValue: DisclosureStore? = nil
}

private struct DisclosureScopeKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The session screen's store — absent elsewhere (the sub-agent viewer),
    /// where a disclosure keeps its own state, as it always did.
    var disclosureStore: DisclosureStore? {
        get { self[DisclosureStoreKey.self] }
        set { self[DisclosureStoreKey.self] = newValue }
    }

    /// The row — and the level within it — the disclosures below belong to.
    var disclosureScope: String? {
        get { self[DisclosureScopeKey.self] }
        set { self[DisclosureScopeKey.self] = newValue }
    }
}

extension View {
    /// Root the disclosures inside at a row: `id` is the row's identity, which
    /// is what lets a choice outlive the view that made it.
    func disclosureRoot(_ id: String?) -> some View {
        environment(\.disclosureScope, id)
    }

    /// One level deeper, for a row that draws several of the same disclosure
    /// (a group's members, a run's plan blocks).
    func disclosureScope(_ name: String) -> some View {
        transformEnvironment(\.disclosureScope) { scope in
            scope = DisclosureStore.key(scope: scope, name: name)
        }
    }
}

/// A disclosure's open/closed choice, kept in the screen's ``DisclosureStore``
/// under `<scope>/<name>` — nil until the reader makes one, so the row's own
/// default (open while it needs attention, say) goes on applying until then.
/// With no store or no scope in the environment it is plain view state.
///
///     @DisclosureChoice("tool") private var userExpanded: Bool?
@propertyWrapper
struct DisclosureChoice: DynamicProperty {
    @Environment(\.disclosureStore) private var store
    @Environment(\.disclosureScope) private var scope
    /// The choice where there is nowhere to keep it — and, either way, what
    /// redraws the row the moment it is made.
    @State private var local: Bool? = nil
    private let name: String

    init(_ name: String) {
        self.name = name
    }

    var wrappedValue: Bool? {
        get {
            if let store = store, let key = DisclosureStore.key(scope: scope, name: name) {
                return store.choice(key)
            }
            return local
        }
        nonmutating set {
            local = newValue
            if let store = store, let key = DisclosureStore.key(scope: scope, name: name) {
                store.set(newValue, for: key)
            }
        }
    }
}
