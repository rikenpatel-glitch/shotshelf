import SwiftUI
import AppKit

// MARK: - Move palette

struct MovePalette: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    let request: MoveRequest
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Option: Identifiable { let id: String; let isNew: Bool; let isRecent: Bool }

    private var options: [Option] {
        let q = query.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let all = NSOrderedSet(array: lib.recentFolders + lib.allFolderPaths + [lib.fallback]).array as? [String] ?? []
        let recent = Set(lib.recentFolders)
        guard !q.isEmpty else { return all.prefix(80).map { Option(id: $0, isNew: false, isRecent: recent.contains($0)) } }
        let scored = all.compactMap { path -> (String, Int)? in
            guard let s = MovePalette.score(q.lowercased(), path.lowercased()) else { return nil }
            return (path, s)
        }
        var out = scored.sorted { $0.1 > $1.1 }.prefix(40).map { Option(id: $0.0, isNew: false, isRecent: recent.contains($0.0)) }
        if !all.contains(where: { $0.lowercased() == q.lowercased() }) { out.append(Option(id: q, isNew: true, isRecent: false)) }
        return out
    }

    /// Substring matches rank first, then in-order letter matches.
    static func score(_ q: String, _ s: String) -> Int? {
        if let r = s.range(of: q) { return 1000 - s.distance(from: s.startIndex, to: r.lowerBound) - s.count / 4 }
        var i = q.startIndex
        for c in s where i < q.endIndex && c == q[i] { i = q.index(after: i) }
        return i == q.endIndex ? 100 - s.count / 4 : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: request.ids.isEmpty ? "folder.badge.plus" : "folder").foregroundStyle(.secondary)
                TextField(request.ids.isEmpty ? "Folder path, like Receipts/Food & Dining/Joe's Pizza" : "Move to folder...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { pick(highlighted) }
                    .onKeyPress(.downArrow) { highlighted = min(options.count - 1, highlighted + 1); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(16)
            Divider()
            HStack {
                Text(request.ids.isEmpty ? request.title : request.ids.count == 1 ? "Moving 1 screenshot" : "Moving \(request.ids.count) screenshots")
                Spacer()
                Text("Return to choose · Esc to cancel")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                            row(o, index: i).id(i)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, h in proxy.scrollTo(h) }
            }
            .frame(height: 340)
        }
        .frame(width: 540)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func row(_ o: Option, index: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: o.isNew ? "plus.circle.fill" : FolderRow.symbol(for: o.id))
                .foregroundStyle(o.isNew ? Color.accentColor : FolderRow.tint(for: o.id))
                .frame(width: 20)
            Text(o.isNew ? "Create \"\(o.id)\"" : o.id).lineLimit(1)
            Spacer()
            if o.isRecent { Text("recent").font(.caption).foregroundStyle(.tertiary) }
            if o.isNew { Text("new folder").font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7).fill(index == highlighted ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = index } }
        .onTapGesture { pick(index) }
    }

    private func pick(_ index: Int) {
        guard options.indices.contains(index) else { return }
        let folder = options[index].id
        dismiss()
        if let onPick = request.onPick { onPick(folder) } else { lib.move(request.ids, to: folder) }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Environment(Library.self) private var lib
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Shotshelf  (Option-Command-S)") { show() }
            .keyboardShortcut("o")
        Divider()
        if lib.recentSorts.isEmpty {
            Text("Take a screenshot and it's sorted here")
        } else {
            Text("Recently sorted")
            ForEach(lib.recentSorts.prefix(6)) { r in
                Button("\(r.folder)  ←  \(r.name)") {
                    lib.scope = .folder(r.folder)
                    show()
                }
            }
        }
        Divider()
        Button("Expenses") { openWindow(id: "expenses"); NSApp.activate(ignoringOtherApps: true) }
        Button("Clean Up...") { openWindow(id: "cleanup"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Toggle("Auto-Sort New Screenshots", isOn: Binding(get: { !lib.paused }, set: { lib.paused = !$0; if $0 { lib.sortInbox() } }))
        Toggle("Notify When Sorted", isOn: Binding(get: { Notifier.shared.enabled }, set: { Notifier.shared.enabled = $0 }))
        Button("Sort Inbox Now") { lib.sortInbox() }
        Toggle("Open at Login", isOn: Binding(get: { lib.opensAtLogin }, set: { lib.opensAtLogin = $0 }))
        Divider()
        SettingsLink { Text("Settings...") }.keyboardShortcut(",")
        Button("Quit Shotshelf") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        Form {
            Section("Screenshots") {
                LabeledContent("Folder") {
                    HStack {
                        Text(AppConfig.tilde(lib.root)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Change...") { chooseRoot() }
                    }
                }
                LabeledContent("macOS saves to") {
                    HStack {
                        Text(AppConfig.tilde(Paths.systemScreenshotFolder)).foregroundStyle(.secondary)
                        if Paths.systemScreenshotFolder.path != lib.root.path {
                            Button("Use Shotshelf Folder") { pointSystemScreenshots(to: lib.root) }
                        }
                    }
                }
                Toggle("Auto-sort new screenshots", isOn: Binding(get: { !lib.paused }, set: { lib.paused = !$0 }))
                Toggle("Open at login", isOn: Binding(get: { lib.opensAtLogin }, set: { lib.opensAtLogin = $0 }))
                Toggle("Notify when a screenshot is sorted", isOn: Binding(get: { Notifier.shared.enabled }, set: { Notifier.shared.enabled = $0 }))
                LabeledContent("Open Shotshelf from anywhere") { Text("Option-Command-S").foregroundStyle(.secondary) }
            }
            Section {
                ForEach(lib.config.projectsDirs, id: \.self) { dir in
                    HStack {
                        Image(systemName: "folder")
                        Text(AppConfig.tilde(dir))
                        Spacer()
                        Button(role: .destructive) { removeProjects(dir) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Code Folder...") { addProjects() }
            } header: {
                Text("Projects")
            } footer: {
                Text("Development screenshots are sorted into a folder per project when a project's name appears on screen.")
                    .foregroundStyle(.secondary)
            }
            Section("Rules") {
                HStack {
                    Button("Edit Config File") { NSWorkspace.shared.open(Paths.configFile) }
                    Button("Reload") { lib.reloadConfig() }
                    Spacer()
                    Button("Re-sort \(lib.fallback)") {
                        lib.resort(lib.shots.filter { $0.folder == lib.fallback }.map(\.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = lib.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppConfig.write(["screenshots_dir": AppConfig.tilde(url)])
        lib.reloadConfig()
    }

    private func addProjects() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let dirs = (lib.config.projectsDirs + panel.urls).map(AppConfig.tilde)
        AppConfig.write(["projects_dirs": Array(NSOrderedSet(array: dirs).array as? [String] ?? dirs)])
        lib.reloadConfig()
    }

    private func removeProjects(_ dir: URL) {
        AppConfig.write(["projects_dirs": lib.config.projectsDirs.filter { $0 != dir }.map(AppConfig.tilde)])
        lib.reloadConfig()
    }
}

/// Point macOS's screenshot location at a folder (same as Screenshot app > Options > Save to).
func pointSystemScreenshots(to url: URL) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    task.arguments = ["write", "com.apple.screencapture", "location", url.path]
    try? task.run()
    task.waitUntilExit()
    let restart = Process()
    restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    restart.arguments = ["SystemUIServer"]
    try? restart.run()
}

// MARK: - First run

struct WelcomeView: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var folder = Paths.home.appendingPathComponent("Pictures/Screenshots")
    @State private var redirect = true

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            Text("Welcome to Shotshelf").font(.title.weight(.bold))
            Text("Every screenshot you take is read on this Mac and filed into a folder like Receipts, Development or Documents. Nothing leaves your computer.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Screenshots folder")
                        Spacer()
                        Text(AppConfig.tilde(folder)).foregroundStyle(.secondary)
                        Button("Change...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { folder = url }
                        }
                    }
                    Toggle("Save new screenshots to this folder", isOn: $redirect)
                }
                .padding(6)
            }
            .frame(width: 460)
            Button("Get Started") { finish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
    }

    private func finish() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        AppConfig.write(["screenshots_dir": AppConfig.tilde(folder), "projects_dirs": [String](), "extra_rules": [[String: Any]]()])
        if redirect { pointSystemScreenshots(to: folder) }
        dismiss()
        lib.reloadConfig()
        lib.opensAtLogin = true
    }
}
