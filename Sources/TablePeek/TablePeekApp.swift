import AppKit
import SwiftUI
import TablePeekCore

@main
struct TablePeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("TablePeek", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 700, minHeight: 420)
        }
        .defaultSize(width: 1200, height: 760)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.presentOpenPanel() }.keyboardShortcut("o")
        }
        CommandGroup(after: .toolbar) {
            Button("Quick View") { model.mode = .quick }.keyboardShortcut("1")
            Button("PDF View") { model.mode = .pdf }.keyboardShortcut("2")
            Button("Source") { model.mode = .source }.keyboardShortcut("3")
            Button("Toggle Quick / PDF") { model.mode = model.mode == .pdf ? .quick : .pdf }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Zoom In") { model.zoom = min(4, model.zoom * 1.15) }.keyboardShortcut("+")
            Button("Zoom In") { model.zoom = min(4, model.zoom * 1.15) }.keyboardShortcut("=")
            Button("Zoom Out") { model.zoom = max(0.3, model.zoom / 1.15) }.keyboardShortcut("-")
            Button("Actual Size") { model.zoom = 1 }.keyboardShortcut("0")
            Divider()
        }
        CommandMenu("Table") {
            Button("Recompile PDF") { model.rerender() }.keyboardShortcut("r")
            Button("Next File") { model.selectNeighbor(1) }.keyboardShortcut(.downArrow, modifiers: [.command])
            Button("Previous File") { model.selectNeighbor(-1) }.keyboardShortcut(.upArrow, modifiers: [.command])
            Divider()
            Button("Open in Editor") { model.openInEditor() }.keyboardShortcut("e")
            Button("Reveal in Finder") { model.revealInFinder() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Open PDF in Preview") { model.openPDFExternally() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Copy LaTeX Source") { model.copySource() }.keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedViaEvent = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare SwiftPM binary (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated {
            let model = AppModel.shared
            // `TablePeek path/to/file.tex` from the command line
            // (Only existing paths count, so `-key value` defaults overrides aren't mistaken for files.)
            let args = CommandLine.arguments.dropFirst()
                .filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
            if let path = args.first {
                model.open(URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
            } else if !openedViaEvent {
                model.restoreLastSession()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedViaEvent = true
        guard let url = urls.first else { return }
        MainActor.assumeIsolated { AppModel.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
