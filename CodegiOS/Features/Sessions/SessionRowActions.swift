import SwiftUI

/// The sheets a Chats row's context menu opens. Each host that shows
/// interactive rows presents them itself — the list, and the full-screen group
/// it zooms into: a cover can't have its presenter put a sheet over it.
struct SessionRowSheets: ViewModifier {
    let client: CodegClient
    /// The conversation whose tags are being edited.
    @Binding var tagging: ConversationSummary?

    func body(content: Content) -> some View {
        content
            .sheet(item: $tagging) { conversation in
                TagPickerSheet(conversation: conversation, client: client)
            }
    }
}

extension View {
    func sessionRowSheets(client: CodegClient, tagging: Binding<ConversationSummary?>) -> some View {
        modifier(SessionRowSheets(client: client, tagging: tagging))
    }
}
