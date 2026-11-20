import SwiftUI
import TablePeekCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var preamble = ""
    @State private var cacheSize: Int64 = 0

    var body: some View {
        @Bindable var model = model
        Form {
            Section("PDF rendering") {
                Picker("Engine", selection: $model.settings.engine) {
                    Text("pdflatex").tag("pdflatex")
                    Text("xelatex").tag("xelatex")
                    Text("lualatex").tag("lualatex")
                }
                TextField("Text width", text: $model.settings.textWidth)
                    .help("\\textwidth used for fragments, e.g. 6.5in. Affects \\resizebox{\\textwidth}, tabularx, etc.")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra preamble (packages, \\newcommand…)")
                    TextEditor(text: $preamble)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    HStack {
                        Text("Used when the file has no \\documentclass. Common table packages are loaded already.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply") { model.settings.extraPreamble = preamble }
                            .disabled(preamble == model.settings.extraPreamble)
                    }
                }
                Toggle("Pre-render recently modified files in the opened folder", isOn: $model.prefetchEnabled)
            }
            Section("Editor") {
                HStack {
                    TextField("Editor app", text: $model.editorPath, prompt: Text("Default app for .tex"))
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [.application]
                        p.directoryURL = URL(fileURLWithPath: "/Applications")
                        if p.runModal() == .OK, let u = p.url { model.editorPath = u.path }
                    }
                }
            }
            Section("Cache") {
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)) in \(PDFRenderer.shared.cacheDir.path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Clear Cache") {
                        PDFRenderer.shared.clearCache()
                        cacheSize = PDFRenderer.shared.cacheSize()
                        model.rerender()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onAppear {
            preamble = model.settings.extraPreamble
            cacheSize = PDFRenderer.shared.cacheSize()
        }
    }
}
