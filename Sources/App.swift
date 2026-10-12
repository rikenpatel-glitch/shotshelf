import SwiftUI
import AppKit

@main
struct ShotshelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = Library.shared

    var body: some Scene {
        Window("Shotshelf", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 860, minHeight: 540)
                .tint(.indigo)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { ShotshelfCommands(library: library) }

        MenuBarExtra {
            MenuBarContent().environment(library)
        } label: {
            Image(systemName: library.paused ? "photo.on.rectangle" : "photo.stack.fill")
        }

        Window("Expenses", id: "expenses") {
            ExpensesView().environment(library).tint(.indigo)
        }
        .defaultSize(width: 760, height: 560)

        Window("Clean Up", id: "cleanup") {
            CleanupView().environment(library).tint(.indigo)
        }
        .defaultSize(width: 900, height: 640)

        Settings {
            SettingsView().environment(library).tint(.indigo)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Library.shared.start() }
        // `open -a Shotshelf --args --open expenses` opens a window by id (main, expenses, cleanup).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            let id = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { Library.shared.openWindow?(id) }
            }
        }
    }

    // Keep sorting in the background after the window closes; the menu bar icon stays.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct ShotshelfCommands: Commands {
    let library: Library
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Expenses") { openWindow(id: "expenses") }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Clean Up...") { openWindow(id: "cleanup") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(replacing: .newItem) {
            Button("New Folder...") { library.moveRequest = MoveRequest(ids: [], title: "New folder") { library.createFolder($0) } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Sort Inbox Now") { library.sortInbox() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        // Single-key shortcuts (Space, M, T, S, P) are handled by the grid itself so they never fire while typing.
        CommandMenu("Screenshots") {
            Button("Open") { if let s = library.selectedShots.first { library.open(s) } }
                .disabled(library.selection.isEmpty)
            Button("Move to Folder...") { library.moveRequest = MoveRequest(ids: Array(library.selection)) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(library.selection.isEmpty)
            Button("Auto-Sort Again") { library.resort(Array(library.selection)) }
                .disabled(library.selection.isEmpty)
            Button("Copy Text") { library.copyText(Array(library.selection)) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(library.selection.isEmpty)
            Button("Show in Finder") { library.reveal(Array(library.selection)) }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(library.selection.isEmpty)
            Button("Move to Trash") { library.trash(Array(library.selection)) }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(library.selection.isEmpty)
            Divider()
            Button("Triage") { library.startTriage() }
                .disabled(!library.canTriage)
            Button("Shuffle") { library.shuffle() }
            Button("Slideshow") { library.startSlideshow() }
        }
    }
}
