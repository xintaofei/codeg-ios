import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if CODEG_TAILSCALEKIT
import TailscaleKit
#endif

/// Userspace Tailscale inside Codeg. Same privacy as Tailscale on both devices,
/// without installing Tailscale.app. Requires TailscaleKit (see
/// `scripts/bootstrap_tailscalekit.sh`).
@MainActor
final class TailnetSession {
    static let shared = TailnetSession()

    private(set) var isStarting = false
    private(set) var lastError: String?
    private var openedLoginURLs = Set<String>()
    private var startTask: Task<Void, Error>?
    #if CODEG_TAILSCALEKIT
    private var node: TailscaleNode?
    #endif

    func session(for url: URL, fallback: URLSession) async -> URLSession {
        guard PrivateHost.needsEmbeddedTailnet(url) else { return fallback }
        do {
            return try await proxied(fallback)
        } catch {
            lastError = error.localizedDescription
            return fallback
        }
    }

    func prepare(for url: URL?) async {
        guard let url, PrivateHost.needsEmbeddedTailnet(url) else { return }
        _ = try? await ensureNode()
    }

    private func proxied(_ fallback: URLSession) async throws -> URLSession {
        #if CODEG_TAILSCALEKIT
        let node = try await ensureNode()
        guard let cfg = fallback.configuration.copy() as? URLSessionConfiguration else {
            return fallback
        }
        _ = try await cfg.proxyVia(node)
        return URLSession(configuration: cfg)
        #else
        throw TailnetError.kitMissing
        #endif
    }

    #if CODEG_TAILSCALEKIT
    private func ensureNode() async throws -> TailscaleNode {
        if let node { return node }
        if let startTask {
            try await startTask.value
            if let node { return node }
        }
        isStarting = true
        lastError = nil
        let task = Task { try await self.startNode() }
        startTask = task
        defer {
            startTask = nil
            isStarting = false
        }
        try await task.value
        guard let node else { throw TailnetError.loginTimeout }
        return node
    }

    private func startNode() async throws {
        let dir = try Self.stateDirectory()
        let config = Configuration(
            hostName: "codeg-ios",
            path: dir.path,
            authKey: nil,
            controlURL: kDefaultControlURL,
            ephemeral: false
        )
        let started = try TailscaleNode(config: config, logger: RedactingTailnetLogger())
        try await started.up()
        node = started

        let api = LocalAPIClient(localNode: started, logger: RedactingTailnetLogger())
        if let status = try? await api.backendStatus(), status.BackendState == "Running" {
            return
        }
        let waiter = TailnetLoginWaiter(onLogin: { [weak self] login in
            await self?.openLoginOnce(login)
        })
        let mask: Ipn.NotifyWatchOpt = [.initialState, .prefs]
        let processor = try await api.watchIPNBus(mask: mask, consumer: waiter)
        defer { processor.cancel() }
        try await api.startLoginInteractive()

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if await waiter.isRunning { return }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw TailnetError.loginTimeout
    }

    private static func stateDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root.appendingPathComponent("codeg-tailnet", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    #else
    private func ensureNode() async throws {
        throw TailnetError.kitMissing
    }
    #endif

    private func openLoginOnce(_ raw: String) async {
        guard !openedLoginURLs.contains(raw), let url = URL(string: raw) else { return }
        openedLoginURLs.insert(raw)
        #if canImport(UIKit)
        await UIApplication.shared.open(url)
        #endif
    }
}

enum TailnetError: LocalizedError {
    case kitMissing
    case loginTimeout

    var errorDescription: String? {
        switch self {
        case .kitMissing:
            return "Private tailnet support is not in this build. On a Mac run scripts/bootstrap_tailscalekit.sh, then xcodegen generate."
        case .loginTimeout:
            return "Timed out waiting for the private tailnet login to finish."
        }
    }
}

#if CODEG_TAILSCALEKIT
private actor TailnetLoginWaiter: MessageConsumer {
    private let onLogin: @MainActor (String) async -> Void
    private(set) var isRunning = false

    init(onLogin: @escaping @MainActor (String) async -> Void) {
        self.onLogin = onLogin
    }

    func notify(_ notify: Ipn.Notify) {
        if notify.State == .Running {
            isRunning = true
        }
        if let url = notify.BrowseToURL, !url.isEmpty {
            Task { @MainActor in
                await onLogin(url)
            }
        }
    }

    func error(_ error: Error) {}
}

private struct RedactingTailnetLogger: LogSink {
    var logFileHandle: Int32? { nil }

    func log(_ message: String) {
        #if DEBUG
        print("[codeg-tailnet]", redact(message))
        #endif
    }

    private func redact(_ message: String) -> String {
        var out = message
        for needle in ["tskey-", "token=", "Authorization:", "Bearer "] {
            if let range = out.range(of: needle, options: .caseInsensitive) {
                out.replaceSubrange(range.lowerBound..<out.endIndex, with: needle + "<redacted>")
            }
        }
        return out
    }
}
#endif
