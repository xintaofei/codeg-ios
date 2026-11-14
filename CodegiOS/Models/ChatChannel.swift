import SwiftUI

/// The three chat-channel backends codeg supports (`channel_type` on the wire).
/// The set is closed and authoritative server-side, so this stays a strict enum.
/// A channel's type is immutable after creation (the update call has no type
/// field), mirroring the web.
enum ChannelType: String, Codable, CaseIterable, Identifiable, Sendable {
    case lark
    case telegram
    case weixin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lark: "Lark / Feishu"
        case .telegram: "Telegram"
        case .weixin: "WeChat"
        }
    }

    var icon: String {
        switch self {
        case .lark: "bird.fill"
        case .telegram: "paperplane.fill"
        case .weixin: "message.fill"
        }
    }

    var tint: Color {
        switch self {
        case .lark: Color(red: 0.20, green: 0.55, blue: 1.0)
        case .telegram: Color(red: 0.15, green: 0.65, blue: 0.95)
        case .weixin: Color(red: 0.10, green: 0.72, blue: 0.30)
        }
    }

    /// Label for the keyring-stored secret entered in the editor, or nil when the
    /// type has no manually-entered token (weixin sets its token via the QR flow).
    var secretLabel: String? {
        switch self {
        case .lark: "App Secret"
        case .telegram: "Bot Token"
        case .weixin: nil
        }
    }
}

/// Live connection state of a channel (`get_chat_channel_status`). Lenient decode:
/// an unknown future status falls back to `.disconnected` rather than failing the
/// whole list.
enum ChannelConnectionStatus: String, Decodable, Sendable {
    case connected
    case connecting
    case disconnected
    case error

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "disconnected"
        self = ChannelConnectionStatus(rawValue: raw) ?? .disconnected
    }

    var label: LocalizedStringKey {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        case .error: "Error"
        }
    }

    var tint: Color {
        switch self {
        case .connected: Color(red: 0.30, green: 0.78, blue: 0.38)
        case .connecting: Theme.warning
        case .disconnected: Theme.textTertiary
        case .error: Theme.danger
        }
    }
}

/// A configured chat channel (`list_chat_channels`). `configJson` is a raw JSON
/// string (per-type config keys are snake_case inside it — parsed via
/// ``ChannelConfig``); the secret token is never part of it. Wire fields are
/// snake_case and decoded by the shared `.convertFromSnakeCase` decoder.
struct ChatChannelInfo: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let channelType: ChannelType
    let enabled: Bool
    let configJson: String
    let eventFilterJson: String?
    let dailyReportEnabled: Bool
    let dailyReportTime: String?

    /// A copy with `enabled` flipped — for optimistic UI in the list/detail
    /// toggles (the struct is immutable, so we rebuild it).
    func with(enabled: Bool) -> ChatChannelInfo {
        ChatChannelInfo(
            id: id, name: name, channelType: channelType, enabled: enabled,
            configJson: configJson, eventFilterJson: eventFilterJson,
            dailyReportEnabled: dailyReportEnabled, dailyReportTime: dailyReportTime
        )
    }
}

/// One row of `get_chat_channel_status` (joined into the list by `channelId`).
struct ChannelStatusInfo: Decodable, Sendable {
    let channelId: Int
    let name: String
    let channelType: ChannelType
    let status: ChannelConnectionStatus
}

/// A delivered/received message log entry (`list_chat_channel_messages`).
/// `direction` ("outbound"/"inbound") and `status` ("sent"/"failed") are kept as
/// strings (lenient) so an unexpected value can't fail the decode.
struct ChatChannelMessageLog: Decodable, Identifiable, Sendable {
    let id: Int
    let channelId: Int
    let direction: String
    let messageType: String
    let contentPreview: String
    let status: String
    let errorDetail: String?
    let createdAt: String?

    var isInbound: Bool { direction.lowercased() == "inbound" }
    var failed: Bool { status.lowercased() == "failed" }
}

/// A global outbound webhook (`get/set_chat_event_webhooks`). Round-trips as
/// `{url, enabled}` (both keys identical in snake/camel).
struct WebhookConfig: Codable, Sendable, Hashable {
    var url: String
    var enabled: Bool
}

/// Weixin login QR (`weixin_get_qrcode`). `qrcode_img_content` is a base64 PNG
/// (optionally a `data:` URI). Snake → camel via the shared decoder.
struct WeixinQrcode: Decodable, Sendable {
    let qrcodeId: String
    let qrcodeImgContent: String
}

/// `weixin_check_qrcode` result — only the status is ever returned (the token is
/// saved server-side on confirmation, never exposed to the client).
struct WeixinQrStatus: Decodable, Sendable {
    let status: String
}

/// Typed view over a channel's `config_json`. Holds every per-type field; only
/// the keys relevant to a type are emitted by ``toJSON(type:)`` (snake_case, to
/// match the server). Mirrors the web's per-type config structs:
/// telegram `{chat_id}`, lark `{app_id, chat_id}`, weixin `{base_url}`.
struct ChannelConfig: Equatable, Sendable {
    var chatId = ""
    var appId = ""
    var baseUrl = ""

    static let weixinDefaultBaseUrl = "https://ilinkai.weixin.qq.com"

    static func parse(_ json: String?) -> ChannelConfig {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ChannelConfig()
        }
        func str(_ key: String) -> String {
            (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ChannelConfig(chatId: str("chat_id"), appId: str("app_id"), baseUrl: str("base_url"))
    }

    /// Build the `config_json` string for `type` with snake_case keys.
    func toJSON(type: ChannelType) -> String {
        var obj: [String: String] = [:]
        let chat = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .telegram:
            obj["chat_id"] = chat
        case .lark:
            obj["app_id"] = appId.trimmingCharacters(in: .whitespacesAndNewlines)
            obj["chat_id"] = chat
        case .weixin:
            let url = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            obj["base_url"] = url.isEmpty ? Self.weixinDefaultBaseUrl : url
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// A short human-readable summary for the detail screen.
    func summary(type: ChannelType) -> String {
        switch type {
        case .telegram: chatId.isEmpty ? String(localized: "No chat ID") : String(localized: "Chat \(chatId)")
        case .lark: [appId, chatId].filter { !$0.isEmpty }.joined(separator: " · ")
        case .weixin: baseUrl.isEmpty ? Self.weixinDefaultBaseUrl : baseUrl
        }
    }
}

/// The chat-event types that can be forwarded to channels/webhooks
/// (`get/set_chat_event_filter`). A `nil` stored filter means "all on except
/// `user_prompt_sent`" — the default set below.
enum ChatEventCatalog {
    struct Item: Identifiable, Sendable {
        let id: String
        let label: String
        let defaultOn: Bool
        var note: String? = nil
    }

    static let all: [Item] = [
        Item(id: "turn_complete", label: "Turn complete", defaultOn: true),
        Item(id: "error", label: "Errors", defaultOn: true),
        Item(id: "permission_request", label: "Permission requests", defaultOn: true),
        Item(id: "question_request", label: "Questions", defaultOn: true),
        Item(id: "user_prompt_sent", label: "User prompts", defaultOn: false, note: "Exports your prompt text"),
    ]

    /// The default-on set used when the stored filter is `nil`.
    static var defaultEnabled: Set<String> { Set(all.filter(\.defaultOn).map(\.id)) }
}

/// Languages the channel bot can reply in (`get/set_chat_message_language`).
enum ChatLanguageCatalog {
    static let options: [(code: String, label: String)] = [
        ("en", "English"), ("zh-cn", "简体中文"), ("zh-tw", "繁體中文"),
        ("ja", "日本語"), ("ko", "한국어"), ("es", "Español"),
        ("de", "Deutsch"), ("fr", "Français"), ("pt", "Português"), ("ar", "العربية"),
    ]

    static func label(for code: String) -> String {
        options.first { $0.code == code.lowercased() }?.label ?? code
    }
}
