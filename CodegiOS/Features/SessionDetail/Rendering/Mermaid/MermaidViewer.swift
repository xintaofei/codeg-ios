import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What the full-screen diagram viewer shows.
struct MermaidViewerContent {
    let source: String
    let diagram: MermaidDiagram
    let theme: MermaidTheme
    /// The inline picture — the share sheet's preview of the PNG.
    let preview: UIImage
}

/// A diagram full screen (the web's fullscreen dialog): the SVG itself in a
/// live, sandboxed web view — no script, no network — so pinch zoom re-renders
/// the vectors and stays sharp. Copy the source, or share the diagram as PNG
/// or SVG or its source as `.mmd`, under the web's export file names.
struct MermaidViewer: View {
    let content: MermaidViewerContent

    @Environment(\.dismiss) private var dismiss
    @State private var copyTick = 0

    var body: some View {
        let palette = RichBlockPalette(dark: content.theme.dark)
        NavigationStack {
            SandboxedWebView(html: MermaidViewerDocument.html(diagram: content.diagram, background: palette.css),
                             background: palette.uiColor)
                .ignoresSafeArea(edges: .bottom)
                .background(palette.color.ignoresSafeArea())
                .accessibilityLabel(Text("Diagram"))
                .navigationTitle(Text("Diagram"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(Text("Close"))
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = content.source
                            copyTick &+= 1
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel(Text("Copy source"))
                        shareMenu
                    }
                }
        }
        .modifier(ResolvedAccent())
        .sensoryFeedback(.success, trigger: copyTick)
    }

    private var shareMenu: some View {
        Menu {
            ShareLink(item: MermaidPNGExport(diagram: content.diagram),
                      preview: SharePreview(MermaidExport.fileName(.png), image: Image(uiImage: content.preview))) {
                Label("Share as PNG", systemImage: "photo")
            }
            ShareLink(item: MermaidSVGExport(svg: content.diagram.svg),
                      preview: SharePreview(MermaidExport.fileName(.svg))) {
                Label("Share as SVG", systemImage: "square.on.square.dashed")
            }
            ShareLink(item: MermaidSourceExport(source: content.source),
                      preview: SharePreview(MermaidExport.fileName(.mmd))) {
                Label("Share source (.mmd)", systemImage: "doc.plaintext")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel(Text("Share"))
    }
}

/// The viewer's document: the SVG alone, centred and fitted inside the screen
/// (the web's "contain" fit, never enlarged), zoomable to 8×. Content scripts
/// are off in the viewer and the policy forbids them anyway.
enum MermaidViewerDocument {
    static func html(diagram: MermaidDiagram, background: String) -> String {
        let width: String
        if let natural = diagram.natural, natural.width > 0, natural.height > 0 {
            let ratio = natural.width / natural.height
            width = "min(\(css(natural.width))px, calc(100vw - 32px), calc((100vh - 32px) * \(css(ratio))))"
        } else {
            width = "calc(100vw - 32px)"
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src 'unsafe-inline' data:; font-src data:; script-src 'none'; form-action 'none'; frame-src 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1,minimum-scale=1,maximum-scale=8,user-scalable=yes,shrink-to-fit=no">
        <style>
        html,body{margin:0;padding:0;background:\(background);-webkit-text-size-adjust:100%}
        body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px;box-sizing:border-box}
        body>svg{display:block;flex:none;max-width:none;width:\(width);height:auto}
        </style>
        </head>
        <body>\(diagram.svg)</body>
        </html>
        """
    }

    private static func css(_ value: CGFloat) -> String {
        String(format: "%.4f", Double(value))
    }
}

// MARK: - Exports

/// The diagram as a PNG at three times its size (drawn when shared).
struct MermaidPNGExport: Transferable {
    let diagram: MermaidDiagram

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await render(item.diagram)
        }
        .suggestedFileName(MermaidExport.fileName(.png))
    }

    @MainActor
    private static func render(_ diagram: MermaidDiagram) async throws -> Data {
        try await WebRenderHost.shared.mermaidPNG(diagram)
    }
}

/// The rendered SVG markup.
struct MermaidSVGExport: Transferable {
    let svg: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .svg) { item in
            Data(item.svg.utf8)
        }
        .suggestedFileName(MermaidExport.fileName(.svg))
    }
}

/// The fence's source, as the web's "Download source (.mmd)".
struct MermaidSourceExport: Transferable {
    let source: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { item in
            Data(item.source.utf8)
        }
        .suggestedFileName(MermaidExport.fileName(.mmd))
    }
}
