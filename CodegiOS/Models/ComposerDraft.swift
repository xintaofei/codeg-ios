import Foundation

/// Unsent composer text for one persisted conversation. Wire fields are
/// snake_case; `CodegJSON.decoder` converts them.
struct ComposerDraft: Decodable, Sendable {
    let conversationId: Int
    let text: String
    let revision: Int
    let origin: String
    let attachments: [ComposerDraftAttachment]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try c.decode(Int.self, forKey: .conversationId)
        text = try c.decode(String.self, forKey: .text)
        revision = try c.decode(Int.self, forKey: .revision)
        origin = try c.decode(String.self, forKey: .origin)
        attachments = try c.decodeIfPresent([ComposerDraftAttachment].self, forKey: .attachments) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case conversationId, text, revision, origin, attachments
    }
}

struct ComposerDraftAttachment: Codable, Hashable, Sendable {
    let id: String
    let kind: String
    let name: String
    let mime: String?
    let size: UInt64?
    let path: String?
    let uri: String?
}

struct ComposerDraftPutResult: Decodable, Sendable {
    let conversationId: Int
    let revision: Int
    let origin: String
    let cleared: Bool
}

/// Ids-only WS payload for `composer-draft://changed`. Never carries `text`.
struct ComposerDraftChanged: Decodable, Sendable {
    static let channel = "composer-draft://changed"

    let conversationId: Int
    let revision: Int
    let origin: String
    let cleared: Bool
}

enum ComposerDraftOrigin {
    private static let defaultsKey = "codeg.composer-draft.origin"

    /// Stable per-install origin so this phone can ignore its own notify.
    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey),
           !existing.isEmpty, existing.count <= 64 {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: defaultsKey)
        return fresh
    }
}

enum ComposerDraftPolicy {
    static func shouldApply(
        remoteRevision: Int,
        lastAppliedRevision: Int,
        remoteOrigin: String,
        localOrigin: String
    ) -> Bool {
        if remoteOrigin == localOrigin { return false }
        return remoteRevision > lastAppliedRevision
    }
}
