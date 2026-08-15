import Foundation

/// Desktop Web Service QR payload. Keep in lock-step with
/// `src/lib/codeg-pairing.ts` in the Codeg desktop repo.
struct CodegPairing: Equatable, Sendable {
    enum Mode: String, Sendable {
        case local
        case privateTailnet = "private"
        case publicInternet = "public"
    }

    var url: URL
    var token: String?
    var name: String?
    var mode: Mode
}

enum CodegPairingParser {
    static func parse(_ raw: String) -> CodegPairing? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let candidate = (object["url"] ?? object["address"] ?? object["server"]) as? String
            guard let candidate, let url = Self.url(from: candidate) else { return nil }
            let token = (object["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let mode = parseMode(object["mode"] as? String, url: url)
            return CodegPairing(
                url: url,
                token: (token?.isEmpty == false) ? token : nil,
                name: (name?.isEmpty == false) ? name : nil,
                mode: mode
            )
        }

        let (address, token) = splitToken(from: trimmed)
        guard let url = Self.url(from: address) else { return nil }
        return CodegPairing(url: url, token: token, name: nil, mode: parseMode(nil, url: url))
    }

    private static func parseMode(_ raw: String?, url: URL) -> CodegPairing.Mode {
        switch raw?.lowercased() {
        case "private": return .privateTailnet
        case "public": return .publicInternet
        case "local": return .local
        default:
            return PrivateHost.needsEmbeddedTailnet(url) ? .privateTailnet : .local
        }
    }

    private static func url(from raw: String) -> URL? {
        ServerEditorModel.normalizedURL(from: raw)
    }

    private static func splitToken(from raw: String) -> (String, String?) {
        guard var components = URLComponents(string: raw),
              let items = components.queryItems, !items.isEmpty else {
            return (raw, nil)
        }
        let token = items.first { $0.name.lowercased() == "token" }?.value
        let remaining = items.filter { $0.name.lowercased() != "token" }
        components.queryItems = remaining.isEmpty ? nil : remaining
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (components.string ?? raw, (cleaned?.isEmpty == false) ? cleaned : nil)
    }
}
