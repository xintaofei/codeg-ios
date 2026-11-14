import Foundation

/// The page Mermaid runs in: an empty `about:` document the renderer loads
/// once, hands the bundled `mermaid.min.js` (11.17.2, the version codeg's web
/// client pins) and keeps for every later diagram.
///
/// Mermaid is set up the way the web's engine (`@streamdown/mermaid`) sets it
/// up — `startOnLoad: false`, `securityLevel: "strict"`, error rendering
/// suppressed — with the theme `"dark"` / `"default"` the web picks per color
/// scheme. One difference: the web asks for the generic `monospace` family,
/// which WebKit on iOS resolves to Courier; this asks for the system monospace
/// face first.
enum MermaidHost {
    static let fontFamily = "ui-monospace, Menlo, monospace"

    /// The bundled library, read off the main thread. Not kept: it is only
    /// needed again if the page has to be rebuilt.
    static func libraryScript() async throws -> String {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else {
            throw WebRenderError.unavailable
        }
        return try await Task.detached(priority: .userInitiated) {
            try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    /// The host document. The stage holds the diagram being drawn at its
    /// top-left corner, where the renderer captures it.
    static let pageHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,shrink-to-fit=no">
    <style>
    html,body{margin:0;padding:0;background:transparent;-webkit-text-size-adjust:100%}
    #codeg-stage{position:absolute;left:0;top:0}
    #codeg-stage>svg{display:block}
    </style>
    </head>
    <body><div id="codeg-stage"></div></body>
    </html>
    """

    /// Installs `window.__codegMermaid` once the library has run:
    /// - `render(source, theme, font)` → `{ok, svg}` or `{ok: false, message}`;
    ///   re-initializes Mermaid only when the configuration changes;
    /// - `stage(svg, width, height, background)` puts the SVG on the stage at
    ///   `width` CSS pixels (and `height`, or the viewBox's ratio when 0) and
    ///   returns its laid-out box;
    /// - `clear()` empties the stage.
    static let bootstrapScript = """
    (() => {
      let current = "";
      let seq = 0;
      const stage = () => document.getElementById("codeg-stage");
      window.__codegMermaid = {
        async render(source, theme, font) {
          const config = {
            startOnLoad: false,
            theme,
            securityLevel: "strict",
            fontFamily: font,
            suppressErrorRendering: true,
          };
          const key = JSON.stringify(config);
          if (key !== current) {
            mermaid.initialize(config);
            current = key;
          }
          seq += 1;
          const id = "codeg-mermaid-" + seq;
          try {
            const result = await mermaid.render(id, source);
            return { ok: true, svg: String(result.svg) };
          } catch (error) {
            for (const stray of [document.getElementById(id), document.getElementById("d" + id)]) {
              if (stray) stray.remove();
            }
            const message = error && typeof error.message === "string" ? error.message : String(error);
            return { ok: false, message };
          }
        },
        stage(svg, width, height, background) {
          document.documentElement.style.background = background;
          const host = stage();
          host.innerHTML = svg;
          const el = host.querySelector("svg");
          if (!el) return null;
          el.style.display = "block";
          el.style.maxWidth = "none";
          el.style.width = width + "px";
          el.style.height = height > 0 ? height + "px" : "auto";
          const box = el.getBoundingClientRect();
          return { width: box.width, height: box.height };
        },
        clear() {
          stage().innerHTML = "";
        },
      };
      return true;
    })();
    """

    static let renderCall = "return await window.__codegMermaid.render(source, theme, font);"
    static let stageCall = "return window.__codegMermaid.stage(svg, width, height, background);"
    static let clearCall = "window.__codegMermaid.clear(); return true;"
}
