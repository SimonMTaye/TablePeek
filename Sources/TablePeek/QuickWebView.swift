import SwiftUI
import TablePeekCore
import WebKit

/// The fast, parsed HTML preview. One WKWebView is kept alive; updates are pushed via JS so
/// switching files never reloads the page (no flash, keeps scroll when the same file changes).
struct QuickWebView: NSViewRepresentable {
    var html: String
    var documentToken: Int
    var zoom: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsMagnification = true
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        let script = """
        <script>
        window.tpRender = function(html, reset) {
          document.getElementById('root').innerHTML = html;
          if (reset) window.scrollTo(0, 0);
        };
        </script>
        """
        web.loadHTMLString(HTMLRenderer.page(body: "", extraHead: FontLoader.css + script), baseURL: nil)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        if web.pageZoom != zoom { web.pageZoom = zoom }
        if c.lastHTML == html && c.lastToken == documentToken { return }
        let reset = c.lastToken != documentToken
        c.lastHTML = html
        c.lastToken = documentToken
        c.push(html: html, reset: reset)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        var lastHTML: String?
        var lastToken: Int?
        private var loaded = false
        private var pending: (String, Bool)?

        func push(html: String, reset: Bool) {
            guard loaded, let web else {
                pending = (html, reset)
                return
            }
            let data = (try? JSONEncoder().encode([html])) ?? Data("[\"\"]".utf8)
            let arg = String(decoding: data, as: UTF8.self)
            web.evaluateJavaScript("tpRender(\(arg)[0], \(reset));", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let (h, r) = pending {
                pending = nil
                push(html: h, reset: r)
            }
        }

        // Never navigate away (e.g. a stray link click).
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }
    }
}

/// Embeds Latin Modern (from the TeX installation) so the quick view looks like LaTeX output.
enum FontLoader {
    static let css: String = {
        let names = [
            ("lmroman10-regular.otf", "LMRoman", "normal", "normal"),
            ("lmroman10-bold.otf", "LMRoman", "bold", "normal"),
            ("lmroman10-italic.otf", "LMRoman", "normal", "italic"),
            ("lmroman10-bolditalic.otf", "LMRoman", "bold", "italic"),
            ("lmmono10-regular.otf", "LMMono", "normal", "normal"),
        ]
        guard let dir = fontDirectory() else { return "" }
        var out = "<style>"
        for (file, family, weight, style) in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { continue }
            out += "@font-face{font-family:'\(family)';font-weight:\(weight);font-style:\(style);src:url(data:font/otf;base64,\(data.base64EncodedString())) format('opentype');}"
        }
        return out + "</style>"
    }()

    private static func fontDirectory() -> URL? {
        let candidates = [
            Bundle.main.resourcePath ?? "",  // bundled copy (release builds), so no TeX install is needed
            "/Library/TeX/Root/texmf-dist/fonts/opentype/public/lm",
            "/usr/local/texlive/texmf-dist/fonts/opentype/public/lm",
            "/opt/homebrew/share/texmf-dist/fonts/opentype/public/lm",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c + "/lmroman10-regular.otf") {
            return URL(fileURLWithPath: c)
        }
        // Ask kpathsea as a last resort.
        guard let kpse = ["/Library/TeX/texbin/kpsewhich", "/opt/homebrew/bin/kpsewhich", "/usr/local/bin/kpsewhich"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: kpse)
        p.arguments = ["lmroman10-regular.otf"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).deletingLastPathComponent()
    }
}
