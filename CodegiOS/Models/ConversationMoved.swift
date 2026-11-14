import Foundation

/// The backend refused a prompt because the user moved the conversation to
/// another folder, and the connection it arrived on runs in the folder the
/// conversation left (it would run the turn in the old directory). Port of web
/// `src/lib/conversation-moved.ts` (codeg 0.44).
///
/// Recognised by text, as the web does: `AcpError::ConversationMoved`
/// reaches the HTTP client as a generic `invalid_input` whose message is the
/// error's stable Display string, `conversation moved to another folder
/// (folder <id>)` — which also names the folder it moved to.
struct ConversationMoved: Equatable, Sendable {
    /// The folder the conversation is in now, when the message named it.
    let folderId: Int?

    private static let marker = "conversation moved to another folder"
    private static let folderPattern = try! NSRegularExpression(
        pattern: #"conversation moved to another folder \(folder (\d+)\)"#
    )

    /// The move `message` reports, or nil when it is some other failure.
    static func from(message: String) -> ConversationMoved? {
        guard message.contains(marker) else { return nil }
        let ns = message as NSString
        let match = folderPattern.firstMatch(in: message, range: NSRange(location: 0, length: ns.length))
        let id = match.flatMap { Int(ns.substring(with: $0.range(at: 1))) }
        return ConversationMoved(folderId: id)
    }

    /// The same, read off a send's thrown error.
    static func from(_ error: Error) -> ConversationMoved? {
        guard case APIError.server(_, _, let message) = error else { return nil }
        return from(message: message)
    }
}
