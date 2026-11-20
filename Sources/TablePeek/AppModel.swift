import AppKit
import Foundation
import Observation
import TablePeekCore

enum ViewMode: String, CaseIterable, Identifiable {
    case quick, pdf, source
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quick: "Quick"
        case .pdf: "PDF"
        case .source: "Source"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case name, modified
}

struct TexFile: Identifiable, Hashable {
    let url: URL
    let name: String
    let directory: String  // relative to root, "" for top level
    let modified: Date
    var id: URL { url }
}

enum PDFState: Equatable {
    case idle
    case rendering
    case ready(url: URL, errors: [String], seconds: Double)
    case failed(errors: [String], log: String)
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Browsing
    var rootURL: URL?
    var files: [TexFile] = []
    var filter = ""
    var sortOrder: SortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .name {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder") }
    }
    private(set) var selection: URL?

    // Current document
    var mode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .quick {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    private(set) var source = ""
    private(set) var quickHTML = ""
    private(set) var quickInfo = ""
    private(set) var pdfState: PDFState = .idle
    /// Bumped when switching files so views can reset scroll position.
    private(set) var documentToken = 0
    var zoom: Double = 1.0

    // Settings
    var settings: RenderSettings = AppModel.loadSettings() {
        didSet {
            if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "renderSettings") }
            if oldValue != settings { startPDF(force: false) }
        }
    }
    var prefetchEnabled: Bool = UserDefaults.standard.object(forKey: "prefetch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(prefetchEnabled, forKey: "prefetch") }
    }
    var editorPath: String = UserDefaults.standard.string(forKey: "editorPath") ?? "" {
        didSet { UserDefaults.standard.set(editorPath, forKey: "editorPath") }
    }

    private var watcher: FolderWatcher?
    private var renderTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var rescanPending = false

    private static func loadSettings() -> RenderSettings {
        guard let d = UserDefaults.standard.data(forKey: "renderSettings"),
              let s = try? JSONDecoder().decode(RenderSettings.self, from: d) else { return RenderSettings() }
        return s
    }

    var visibleFiles: [TexFile] {
        var list = files
        if !filter.isEmpty {
            let f = filter.lowercased()
            list = list.filter { $0.name.lowercased().contains(f) || $0.directory.lowercased().contains(f) }
        }
        switch sortOrder {
        case .name: return list
        case .modified: return list.sorted { $0.modified > $1.modified }
        }
    }

    var selectedFile: TexFile? { files.first { $0.url == selection } }

    // MARK: - Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "tex")!, .folder]
        panel.message = "Choose a .tex file or a folder of tables"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if isDir.boolValue {
            setRoot(url, select: nil)
        } else {
            // Keep the current root if the file lives inside it; otherwise browse its folder.
            if let root = rootURL, url.path.hasPrefix(root.path + "/") {
                select(url)
            } else {
                setRoot(url.deletingLastPathComponent(), select: url)
            }
        }
    }

    func restoreLastSession() {
        guard rootURL == nil, let path = UserDefaults.standard.string(forKey: "lastRoot") else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        let sel = UserDefaults.standard.string(forKey: "lastSelection").map { URL(fileURLWithPath: $0) }
        setRoot(URL(fileURLWithPath: path), select: sel.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }

    private func setRoot(_ dir: URL, select file: URL?) {
        rootURL = dir
        UserDefaults.standard.set(dir.path, forKey: "lastRoot")
        files = []
        filter = ""
        Task { await PDFRenderer.shared.cancelPrefetch() }
        watcher = FolderWatcher(path: dir.path) { [weak self] paths in
            MainActor.assumeIsolated { self?.handleFSEvents(paths) }
        }
        if let file { select(file) } else { select(nil) }
        rescan(prefetch: true)
    }

    // MARK: - Folder scanning

    private func rescan(prefetch: Bool = false) {
        guard let root = rootURL else { return }
        scanTask?.cancel()
        scanTask = Task {
            let found = await Task.detached(priority: .userInitiated) { Self.scan(root) }.value
            guard !Task.isCancelled, self.rootURL == root else { return }
            self.files = found
            if self.selection == nil, let first = found.first { self.select(first.url) }
            if prefetch && self.prefetchEnabled {
                let recent = found.sorted { $0.modified > $1.modified }.prefix(60).map(\.url)
                await PDFRenderer.shared.prefetch(Array(recent), settings: self.settings)
            }
        }
    }

    nonisolated static func scan(_ root: URL) -> [TexFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [TexFile] = []
        var visited = 0
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in en {
            visited += 1
            if visited > 200_000 || out.count >= 5000 { break }
            let name = url.lastPathComponent
            if en.level > 8 || name == "node_modules" { en.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "tex" else { continue }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            if vals?.isDirectory == true { continue }
            let full = url.standardizedFileURL
            var dir = full.deletingLastPathComponent().path
            dir = dir.hasPrefix(rootPath) ? String(dir.dropFirst(rootPath.count)) : dir
            if dir.hasPrefix("/") { dir.removeFirst() }
            out.append(TexFile(url: full, name: name, directory: dir, modified: vals?.contentModificationDate ?? .distantPast))
        }
        out.sort {
            if $0.directory != $1.directory {
                if $0.directory.isEmpty { return true }
                if $1.directory.isEmpty { return false }
                return $0.directory.localizedStandardCompare($1.directory) == .orderedAscending
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return out
    }

    private func handleFSEvents(_ paths: [String]) {
        let selPath = selection?.resolvingSymlinksInPath().path
        var touchedSelection = false
        var structural = false
        for p in paths {
            let resolved = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            if resolved == selPath { touchedSelection = true }
            if p.hasSuffix(".tex") || !p.contains(".") { structural = true }
        }
        if touchedSelection { reloadSelection() }
        if structural && !rescanPending {
            rescanPending = true
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                self.rescanPending = false
                self.rescan()
            }
        }
    }

    // MARK: - Selection & rendering

    func select(_ url: URL?) {
        guard url != selection || url == nil else { return }
        selection = url
        if let url { UserDefaults.standard.set(url.path, forKey: "lastSelection") }
        documentToken += 1
        source = ""
        load()
    }

    func selectNeighbor(_ delta: Int) {
        let list = visibleFiles
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.url == selection } ?? (delta > 0 ? -1 : list.count)
        let next = max(0, min(list.count - 1, idx + delta))
        select(list[next].url)
    }

    func reloadSelection() { load() }

    private func load() {
        guard let url = selection else {
            source = ""
            quickHTML = ""
            quickInfo = ""
            pdfState = .idle
            return
        }
        guard let src = PDFRenderer.readSource(url) else {
            quickHTML = "<div class=\"empty\">Could not read file.</div>"
            pdfState = .failed(errors: ["Could not read \(url.lastPathComponent)"], log: "")
            return
        }
        if src == source && pdfState != .idle { return }  // spurious FS event
        source = src
        let parsed = TableParser.parse(src)
        quickHTML = HTMLRenderer.bodyHTML(parsed)
        let n = parsed.tables.count
        quickInfo = n == 0 ? "no tables" : "\(n) table\(n == 1 ? "" : "s")"
        startPDF(force: false)
    }

    func rerender() { startPDF(force: true) }

    private func startPDF(force: Bool) {
        renderTask?.cancel()
        guard let url = selection, !source.isEmpty else { return }
        let job = RenderJob(source: source, fileURL: url, settings: settings)
        if !force, let cached = PDFRenderer.shared.cached(job) {
            apply(cached)
            return
        }
        pdfState = .rendering
        renderTask = Task {
            let result = await PDFRenderer.shared.render(job, force: force)
            guard !Task.isCancelled, self.selection == url, self.source == job.source else { return }
            self.apply(result)
        }
    }

    private func apply(_ r: RenderOutcome) {
        switch r {
        case let .success(pdf, errors, secs): pdfState = .ready(url: pdf, errors: errors, seconds: secs)
        case let .failure(errors, log): pdfState = .failed(errors: errors, log: log)
        }
    }

    // MARK: - Actions

    var currentPDF: URL? {
        if case let .ready(url, _, _) = pdfState { return url }
        return nil
    }

    func openInEditor() {
        guard let url = selection else { return }
        let ws = NSWorkspace.shared
        if !editorPath.isEmpty {
            ws.open([url], withApplicationAt: URL(fileURLWithPath: editorPath), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let defaultApp = ws.urlForApplication(toOpen: url)
        if defaultApp == nil || defaultApp == Bundle.main.bundleURL,
           let textEdit = ws.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            ws.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            ws.open(url)
        }
    }

    func revealInFinder() {
        guard let url = selection else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openPDFExternally() {
        guard let pdf = currentPDF, let sel = selection else { return }
        // Give it a friendly name so Preview's title bar is meaningful.
        let named = FileManager.default.temporaryDirectory
            .appendingPathComponent(sel.deletingPathExtension().lastPathComponent + ".pdf")
        try? FileManager.default.removeItem(at: named)
        try? FileManager.default.copyItem(at: pdf, to: named)
        NSWorkspace.shared.open(named)
    }

    func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }
}
