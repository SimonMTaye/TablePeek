import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Finder spacebar preview for .tex tables: runs the quick parser and returns HTML.
/// Compiled together with the TablePeekCore parser sources by scripts/build-app.sh.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let result = TableParser.parse(source)
        var body = HTMLRenderer.bodyHTML(result)
        if result.tables.isEmpty {
            // Not a table: show the LaTeX source instead of an empty page.
            body = "<pre style=\"font:12px Menlo,monospace;white-space:pre-wrap;color:inherit\">\(HTMLEscape.escape(source))</pre>"
        }
        let html = HTMLRenderer.page(body: body, extraHead: Self.fontCSS)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 1000, height: 700)) { _ in
            Data(html.utf8)
        }
    }

    /// Latin Modern fonts copied into the extension bundle at build time (if TeX was installed).
    static let fontCSS: String = {
        let faces = [
            ("lmroman10-regular", "LMRoman", "normal", "normal"),
            ("lmroman10-bold", "LMRoman", "bold", "normal"),
            ("lmroman10-italic", "LMRoman", "normal", "italic"),
            ("lmroman10-bolditalic", "LMRoman", "bold", "italic"),
            ("lmmono10-regular", "LMMono", "normal", "normal"),
        ]
        var css = "<style>"
        for (file, family, weight, style) in faces {
            guard let url = Bundle.main.url(forResource: file, withExtension: "otf"),
                  let d = try? Data(contentsOf: url) else { continue }
            css += "@font-face{font-family:'\(family)';font-weight:\(weight);font-style:\(style);src:url(data:font/otf;base64,\(d.base64EncodedString())) format('opentype');}"
        }
        return css + "</style>"
    }()
}

enum HTMLEscape {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
