import PDFKit
import SwiftUI

struct PDFKitView: NSViewRepresentable {
    var url: URL
    var documentToken: Int
    var zoom: Double

    func makeNSView(context: Context) -> FittingPDFView {
        let v = FittingPDFView()
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.pageShadowsEnabled = true
        v.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.165, alpha: 1) : NSColor(calibratedWhite: 0.914, alpha: 1)
        }
        return v
    }

    func updateNSView(_ v: FittingPDFView, context: Context) {
        v.zoom = zoom
        if v.loadedURL != url {
            let sameDocument = v.loadedToken == documentToken
            let oldScale = v.scaleFactor
            let oldDest = v.currentDestination
            v.loadedURL = url
            v.loadedToken = documentToken
            v.document = PDFDocument(url: url)
            if sameDocument && v.userZoomed {
                // Re-render of the same file: keep the user's zoom and position.
                v.scaleFactor = oldScale
                if let d = oldDest, let page = v.document?.page(at: 0) {
                    v.go(to: PDFDestination(page: page, at: d.point))
                }
            } else {
                v.userZoomed = false
                v.applyFit()
            }
        } else {
            v.applyFit()
        }
    }
}

/// PDFView that sizes the page to fit the width, but never blows small tables up beyond ~150%.
final class FittingPDFView: PDFView {
    var loadedURL: URL?
    var loadedToken: Int?
    var zoom: Double = 1
    var userZoomed = false
    private var applying = false

    func applyFit() {
        guard !userZoomed, document != nil, bounds.width > 0 else { return }
        applying = true
        autoScales = false
        let fit = scaleFactorForSizeToFit
        let target = max(0.1, min(fit, 1.5)) * zoom
        if abs(scaleFactor - target) > 0.001 { scaleFactor = target }
        applying = false
    }

    override func layout() {
        super.layout()
        applyFit()
    }

    override func magnify(with event: NSEvent) {
        userZoomed = true
        super.magnify(with: event)
    }
}
