import SwiftUI
import UIKit

/// WeChat connect: fetch a login QR (`weixin_get_qrcode`), render it, and poll
/// `weixin_check_qrcode` until the user confirms on their phone (the server saves
/// the token on confirmation — it's never returned here). The poll lives in a
/// `.task(id:)` so it auto-cancels on dismiss and restarts on "Refresh".
struct WeixinQRView: View {
    let channelId: Int
    let client: CodegClient?
    let onConnected: () -> Void

    @State private var attempt = 0
    @State private var phase: Phase = .loading
    @State private var image: UIImage?
    @State private var statusText = "Loading QR code…"
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable { case loading, showing, scanned, expired, confirmed, failed(String) }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                VStack(spacing: 20) {
                    Spacer()
                    qrArea
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    if case .expired = phase { refreshButton }
                    if case .failed = phase { refreshButton }
                    Spacer()
                    Text("Open WeChat, tap the “+” and choose Scan, then point your camera at the code.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding()
            }
            .navigationTitle("Connect WeChat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Theme.textSecondary)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task(id: attempt) { await run() }
    }

    @ViewBuilder
    private var qrArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            switch phase {
            case .loading:
                ProgressView().controlSize(.large).tint(.black)
            case .expired:
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 56)).foregroundStyle(.black.opacity(0.4))
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48)).foregroundStyle(.orange)
            case .confirmed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64)).foregroundStyle(Color(red: 0.10, green: 0.72, blue: 0.30))
            case .showing, .scanned:
                if let image {
                    Image(uiImage: image)
                        .resizable().interpolation(.none)
                        .frame(width: 210, height: 210)
                } else {
                    ProgressView().controlSize(.large).tint(.black)
                }
            }
        }
    }

    private var refreshButton: some View {
        Button { attempt += 1 } label: {
            Label("Refresh QR Code", systemImage: "arrow.clockwise")
        }
        .codegGlassButtonStyle()
        .tint(Theme.accent)
    }

    private func run() async {
        guard let client else { phase = .failed("No server selected."); statusText = "No server selected."; return }
        phase = .loading
        statusText = "Loading QR code…"
        image = nil

        let qr: WeixinQrcode
        do { qr = try await client.weixinGetQrcode() }
        catch {
            phase = .failed(error.localizedDescription)
            statusText = "Couldn’t load the QR code."
            return
        }

        image = Self.decode(qr.qrcodeImgContent)
        phase = .showing
        statusText = "Scan with WeChat"

        // Poll for up to ~2 minutes (60 × 2s). The task is cancelled on dismiss.
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            guard let status = try? await client.weixinCheckQrcode(channelId: channelId, qrcode: qr.qrcodeId) else {
                continue
            }
            let s = status.lowercased()
            if s.contains("confirm") || s == "success" || s == "connected" || s.contains("logged") {
                phase = .confirmed
                statusText = "Connected!"
                try? await Task.sleep(for: .seconds(0.8))
                onConnected()
                dismiss()
                return
            } else if s.contains("expire") {
                phase = .expired
                statusText = "QR code expired."
                return
            } else if s.contains("scan") {
                phase = .scanned
                statusText = "Scanned — confirm in WeChat."
            }
        }
        phase = .expired
        statusText = "QR code expired."
    }

    /// Decode a base64 PNG (optionally a `data:` URI) into an image.
    private static func decode(_ raw: String) -> UIImage? {
        var b64 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if b64.hasPrefix("data:"), let comma = b64.firstIndex(of: ",") {
            b64 = String(b64[b64.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) else { return nil }
        return UIImage(data: data)
    }
}
