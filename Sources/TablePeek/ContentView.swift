import SwiftUI
import TablePeekCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            DetailView()
        }
        .navigationTitle(model.selectedFile?.name ?? model.rootURL?.lastPathComponent ?? "TablePeek")
        .navigationSubtitle(model.selectedFile?.directory ?? "")
        .toolbar { MainToolbar() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.open(url) } }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.rootURL == nil {
                VStack(spacing: 12) {
                    Image(systemName: "tablecells").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Open a folder of .tex tables\nor drop one here").multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Open…") { model.presentOpenPanel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                    ForEach(model.visibleFiles) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name).lineLimit(1).truncationMode(.middle)
                            if !f.directory.isEmpty || model.sortOrder == .modified {
                                Text(subtitle(f)).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                        }
                        .tag(f.url)
                        .help(f.url.path)
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
                            Button("Open in Editor") { model.select(f.url); model.openInEditor() }
                        }
                    }
                }
                .searchable(text: $model.filter, placement: .sidebar, prompt: "Filter")
                .overlay {
                    if model.files.isEmpty {
                        Text("No .tex files").foregroundStyle(.secondary)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text("\(model.visibleFiles.count) files").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Picker("Sort", selection: $model.sortOrder) {
                            Text("Name").tag(SortOrder.name)
                            Text("Recently modified").tag(SortOrder.modified)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
    }

    private func subtitle(_ f: TexFile) -> String {
        if model.sortOrder == .modified {
            let rel = f.modified.formatted(.relative(presentation: .named))
            return f.directory.isEmpty ? rel : "\(rel) · \(f.directory)"
        }
        return f.directory
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selection == nil {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(model.rootURL == nil ? "Open a .tex file or folder (⌘O)" : "Select a table")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .top) {
                // Quick view stays mounted so toggling modes is instant; it also stands in
                // for the PDF while it compiles.
                QuickWebView(html: model.quickHTML, documentToken: model.documentToken, zoom: model.zoom)
                    .opacity(showQuick ? 1 : 0)
                    .allowsHitTesting(showQuick)

                if case let .ready(url, errors, _) = model.pdfState {
                    VStack(spacing: 0) {
                        if !errors.isEmpty { ErrorBanner(errors: errors, compact: true) }
                        PDFKitView(url: url, documentToken: model.documentToken, zoom: model.zoom)
                    }
                    .opacity(model.mode == .pdf ? 1 : 0)
                    .allowsHitTesting(model.mode == .pdf)
                }

                if model.mode == .pdf, case let .failed(errors, log) = model.pdfState {
                    CompileFailedView(errors: errors, log: log)
                }

                if model.mode == .pdf, model.pdfState == .rendering {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Compiling PDF… showing quick preview").font(.callout)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 2, y: 1)
                    .padding(.top, 10)
                    .transition(.opacity)
                }

                if model.mode == .source {
                    SourceView(text: model.source)
                }
            }
        }
    }

    private var showQuick: Bool {
        switch model.mode {
        case .quick: return true
        case .pdf: return model.pdfState == .rendering || model.pdfState == .idle
        case .source: return false
        }
    }
}

struct ErrorBanner: View {
    var errors: [String]
    var compact: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("LaTeX reported \(errors.count) error\(errors.count == 1 ? "" : "s"); output may be incomplete.")
                    .font(.callout)
                Spacer()
                Button(expanded ? "Hide" : "Show") { expanded.toggle() }.controlSize(.small)
            }
            if expanded {
                ForEach(errors, id: \.self) { e in
                    Text(e).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.yellow.opacity(0.12))
    }
}

struct CompileFailedView: View {
    var errors: [String]
    var log: String
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("PDF compilation failed", systemImage: "xmark.octagon.fill")
                    .font(.headline).foregroundStyle(.red)
                ForEach(errors, id: \.self) { e in
                    Text(e).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                Text("Tip: add missing packages or macros under Settings → Extra preamble. The Quick view (⌘1) still works.")
                    .font(.callout).foregroundStyle(.secondary)
                if !log.isEmpty {
                    DisclosureGroup("Full log", isExpanded: $showLog) {
                        Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct SourceView: View {
    var text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.mode) {
                ForEach(ViewMode.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .help("Quick (⌘1) · PDF (⌘2) · Source (⌘3)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            StatusBadge()
            Button { model.rerender() } label: { Image(systemName: "arrow.clockwise") }
                .help("Recompile PDF (⌘R)")
                .disabled(model.selection == nil)
            Menu {
                Button("Open in Editor") { model.openInEditor() }
                Button("Reveal in Finder") { model.revealInFinder() }
                Button("Open PDF in Preview") { model.openPDFExternally() }.disabled(model.currentPDF == nil)
                Divider()
                Button("Copy LaTeX Source") { model.copySource() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(model.selection == nil)
        }
    }
}

struct StatusBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 5) {
            switch model.pdfState {
            case .idle:
                EmptyView()
            case .rendering:
                ProgressView().controlSize(.mini)
                Text("Compiling")
            case let .ready(_, errors, secs):
                Image(systemName: errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(errors.isEmpty ? .green : .yellow)
                Text(secs > 0 ? String(format: "PDF %.1fs", secs) : "PDF cached")
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("PDF failed")
            }
            if !model.quickInfo.isEmpty {
                Text("· \(model.quickInfo)").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .fixedSize()
    }
}
