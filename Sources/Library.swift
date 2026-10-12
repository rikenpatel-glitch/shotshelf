import SwiftUI
import AppKit
import ServiceManagement

struct Shot: Identifiable, Hashable {
    let id: String          // path relative to the screenshots folder
    let url: URL
    let folder: String
    let date: Date
    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct FolderNode: Identifiable, Hashable {
    let id: String          // relative path
    let name: String
    var count: Int
    var total: Int
    var children: [FolderNode]?
}

struct ShotGroup: Identifiable {
    let id: String
    let shots: [Shot]
}

enum Scope: Hashable {
    case all, inbox, folder(String)
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var symbol = "checkmark.circle.fill"
    var undo: (() -> Void)?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct MoveRequest: Identifiable {
    let id = UUID()
    let ids: [String]
    var title = "Move to folder"
    var onPick: ((String) -> Void)?
}

@Observable
@MainActor
final class Library {
    static let shared = Library()

    private(set) var config: AppConfig
    private(set) var sorter: Sorter
    var root: URL { config.root }
    var fallback: String { config.fallback }

    // Library contents
    private(set) var shots: [Shot] = []
    private(set) var tree: [FolderNode] = []
    private(set) var inboxCount = 0
    private(set) var visible: [Shot] = []
    private(set) var groups: [ShotGroup] = []
    private(set) var loaded = false

    // View state
    var scope: Scope = .folder("General") { didSet { if scope != oldValue { selection = []; shuffled = nil; recompute() } } }
    var query = "" { didSet { searchDebounce.call { [weak self] in self?.runSearch() } } }
    private var searchHits: [String]?
    var selection: Set<String> = []
    var anchor: String?
    var newestFirst = true { didSet { shuffled = nil; recompute() } }
    private(set) var shuffled: [String]?
    var thumbSize: Double = UserDefaults.standard.object(forKey: "thumbSize") as? Double ?? 220 {
        didSet { UserDefaults.standard.set(thumbSize, forKey: "thumbSize") }
    }

    // Overlays
    var viewer: [Shot]?
    var viewerIndex = 0
    var slideshow = false
    var triage: [Shot]?
    var triagePos = 0
    var moveRequest: MoveRequest?
    var toast: Toast?
    var showWelcome = !AppConfig.exists

    // Background activity
    var paused = UserDefaults.standard.bool(forKey: "paused") { didSet { UserDefaults.standard.set(paused, forKey: "paused") } }
    private(set) var status = ""
    private(set) var recentSorts: [SortResult] = []
    private(set) var recentFolders: [String] = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []

    private var watcher: FolderWatcher?
    private var hotKey: HotKey?
    /// Opens a window scene by id; set by the first window that appears.
    var openWindow: ((String) -> Void)?
    private let reloadDebounce = Debouncer(0.4)
    private let inboxDebounce = Debouncer(1.2)
    private let searchDebounce = Debouncer(0.18)
    private var toastWork: DispatchWorkItem?
    private var sorting = false

    private init() {
        let cfg = AppConfig()
        config = cfg
        sorter = Sorter(config: cfg)
        scope = .folder(cfg.fallback)
    }

    // MARK: lifecycle

    func start() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if hotKey == nil {
            Notifier.shared.setUp()
            Notifier.shared.onShow = { [weak self] path in self?.showWindow(); self?.focus(path, open: true) }
            Notifier.shared.onMove = { [weak self] path in
                self?.showWindow()
                self?.focus(path)
                self?.moveRequest = MoveRequest(ids: [path])
            }
            // Option-Command-S from anywhere: bring up Shotshelf on the newest screenshot.
            hotKey = HotKey { [weak self] in
                guard let self else { return }
                self.showWindow()
                self.query = ""
                self.scope = .all
                if let newest = self.visible.first { self.open(newest) }
            }
        }
        reload()
        watcher = FolderWatcher(path: root.path) { [weak self] paths in self?.filesChanged(paths) }
        watcher?.start()
        sortInbox()
        let sorter = self.sorter
        sorter.backgroundQueue.async { [weak self] in
            sorter.reconcile { done, total in
                DispatchQueue.main.async { self?.status = done < total ? "Reading text \(done) of \(total)" : "" }
            }
            DispatchQueue.main.async { self?.status = "" }
        }
    }

    /// Re-read the config file (after Settings changes) and restart watching.
    func reloadConfig() {
        watcher?.stop()
        config = AppConfig()
        sorter = Sorter(config: config)
        scope = .folder(config.fallback)
        start()
    }

    private func filesChanged(_ paths: [String]) {
        reloadDebounce.call { [weak self] in self?.reload() }
        let rootPath = root.path
        let touchesInbox = paths.contains { ($0 as NSString).deletingLastPathComponent == rootPath }
        if touchesInbox && !paused { inboxDebounce.call { [weak self] in self?.sortInbox() } }
    }

    func sortInbox() {
        guard !sorting else { inboxDebounce.call { [weak self] in self?.sortInbox() }; return }
        sorting = true
        let sorter = self.sorter
        sorter.queue.async { [weak self] in
            let pending = sorter.inboxFiles(settled: false).count
            let results = sorter.sortInbox()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sorting = false
                if !results.isEmpty {
                    self.recentSorts = Array((results.reversed() + self.recentSorts).prefix(20))
                    Notifier.shared.sorted(results, root: self.root)
                    self.reload()
                }
                // A screenshot that was still being written gets picked up on the next pass.
                if pending > results.count { self.inboxDebounce.call { self.sortInbox() } }
            }
        }
    }

    // MARK: loading

    func reload() {
        let root = self.root
        Task.detached(priority: .userInitiated) {
            let scan = Library.scan(root: root)
            await MainActor.run {
                self.shots = scan.shots
                self.tree = scan.tree
                self.inboxCount = scan.inbox
                self.loaded = true
                self.selection = self.selection.intersection(Set(scan.shots.map(\.id)))
                self.recompute()
            }
        }
    }

    nonisolated private static func scan(root: URL) -> (shots: [Shot], tree: [FolderNode], inbox: Int) {
        let fm = FileManager.default
        var shots: [Shot] = []
        var counts: [String: Int] = [:]
        var dirs = Set<String>()
        let rootPath = root.path
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], [], 0) }
        for case let url as URL in e {
            let rel = String(url.path.dropFirst(rootPath.count + 1))
            if url.hasDirectoryPath { dirs.insert(rel); continue }
            guard ShotFile.isImage(url) else { continue }
            let folder = (rel as NSString).deletingLastPathComponent
            counts[folder, default: 0] += 1
            shots.append(Shot(id: rel, url: url, folder: folder, date: ShotFile.date(url)))
        }
        func build(_ prefix: String) -> [FolderNode] {
            let kids = dirs.filter { ($0 as NSString).deletingLastPathComponent == prefix }
            return kids.map { path in
                let children = build(path)
                let count = counts[path] ?? 0
                return FolderNode(id: path, name: (path as NSString).lastPathComponent, count: count,
                                  total: count + children.reduce(0) { $0 + $1.total },
                                  children: children.isEmpty ? nil : children)
            }
            .sorted { prefix.isEmpty ? ($0.total, $1.name) > ($1.total, $0.name) : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return (shots, build(""), counts[""] ?? 0)
    }

    private func recompute() {
        var list: [Shot]
        if let hits = searchHits {
            let order = Dictionary(hits.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            list = shots.filter { order[$0.id] != nil }
        } else {
            switch scope {
            case .all: list = shots
            case .inbox: list = shots.filter { $0.folder.isEmpty }
            case .folder(let f): list = shots.filter { $0.folder == f || $0.folder.hasPrefix(f + "/") }
            }
        }
        if let order = shuffled {
            let pos = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            list.sort { (pos[$0.id] ?? .max) < (pos[$1.id] ?? .max) }
            groups = [ShotGroup(id: "Shuffled", shots: list)]
        } else {
            list.sort { newestFirst ? $0.date > $1.date : $0.date < $1.date }
            groups = Library.group(list)
        }
        visible = list
    }

    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    static func groupLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day, days < 7 {
            return dayFormat.string(from: date)
        }
        return monthFormat.string(from: date)
    }

    private static func group(_ list: [Shot]) -> [ShotGroup] {
        var out: [ShotGroup] = []
        var current: [Shot] = []
        var label: String?
        for s in list {
            let l = groupLabel(s.date)
            if l != label, let label { out.append(ShotGroup(id: label + "-\(out.count)", shots: current)); current = [] }
            label = l
            current.append(s)
        }
        if let label, !current.isEmpty { out.append(ShotGroup(id: label + "-\(out.count)", shots: current)) }
        return out
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchHits = nil; recompute(); return }
        let index = sorter.index
        Task.detached(priority: .userInitiated) {
            let hits = index.search(q)
            await MainActor.run {
                guard self.query.trimmingCharacters(in: .whitespaces) == q else { return }
                self.searchHits = hits
                self.selection = []
                self.recompute()
            }
        }
    }

    var isSearching: Bool { searchHits != nil }

    var title: String {
        if isSearching { return "Search" }
        switch scope {
        case .all: return "All Screenshots"
        case .inbox: return "Waiting to Sort"
        case .folder(let f): return (f as NSString).lastPathComponent
        }
    }

    var canTriage: Bool {
        guard !isSearching, !visible.isEmpty else { return false }
        if case .folder(let f) = scope { return f == fallback }
        return scope == .inbox
    }

    var allFolderPaths: [String] {
        var out: [String] = []
        func walk(_ nodes: [FolderNode]) { for n in nodes { out.append(n.id); walk(n.children ?? []) } }
        walk(tree)
        return out
    }

    func count(of folder: String) -> Int {
        func find(_ nodes: [FolderNode]) -> Int? {
            for n in nodes { if n.id == folder { return n.total }; if let c = find(n.children ?? []) { return c } }
            return nil
        }
        return find(tree) ?? 0
    }

    // MARK: selection

    func click(_ shot: Shot) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(shot.id) { selection.remove(shot.id) } else { selection.insert(shot.id) }
            anchor = shot.id
        } else if mods.contains(.shift), let anchor, let a = visible.firstIndex(where: { $0.id == anchor }),
                  let b = visible.firstIndex(where: { $0.id == shot.id }) {
            for s in visible[min(a, b)...max(a, b)] { selection.insert(s.id) }
        } else {
            selection = [shot.id]
            anchor = shot.id
        }
    }

    func selectAll() { selection = Set(visible.map(\.id)) }

    var selectedShots: [Shot] { visible.filter { selection.contains($0.id) } }

    // MARK: actions

    func remember(_ folder: String) {
        recentFolders = Array(([folder] + recentFolders.filter { $0 != folder }).prefix(12))
        UserDefaults.standard.set(recentFolders, forKey: "recentFolders")
    }

    /// Moves screenshots and returns their new relative paths.
    @discardableResult
    func move(_ ids: [String], to folder: String, announce: Bool = true) -> [(old: String, new: String)] {
        var moved: [(String, String)] = []
        for id in ids {
            let src = root.appendingPathComponent(id)
            if let dest = try? sorter.move(src, to: folder, how: "manual") {
                moved.append((id, sorter.relative(dest)))
            }
        }
        guard !moved.isEmpty else {
            show(Toast(text: "Couldn't move those screenshots", symbol: "exclamationmark.triangle.fill"))
            return []
        }
        remember(folder)
        applyMoves(moved)
        if announce {
            let n = moved.count
            show(Toast(text: "Moved \(n == 1 ? "1 screenshot" : "\(n) screenshots") to \(folder.isEmpty ? "the inbox" : folder)") { [weak self] in
                self?.undoMoves(moved)
            })
        }
        return moved.map { (old: $0.0, new: $0.1) }
    }

    func undoMoves(_ moved: [(String, String)]) {
        var back: [(String, String)] = []
        for (old, new) in moved {
            let folder = (old as NSString).deletingLastPathComponent
            if let dest = try? sorter.move(root.appendingPathComponent(new), to: folder, how: "manual") {
                back.append((new, sorter.relative(dest)))
            }
        }
        applyMoves(back)
    }

    /// Update the in-memory library right away so the grid reacts instantly; the file watcher confirms later.
    private func applyMoves(_ moved: [(String, String)]) {
        let map = Dictionary(moved, uniquingKeysWith: { a, _ in a })
        withAnimation(.snappy(duration: 0.3)) {
            shots = shots.map { s in
                guard let new = map[s.id] else { return s }
                return Shot(id: new, url: root.appendingPathComponent(new), folder: (new as NSString).deletingLastPathComponent, date: s.date)
            }
            selection.subtract(map.keys)
            recompute()
        }
        reloadDebounce.call { [weak self] in self?.reload() }
    }

    func trash(_ ids: [String]) {
        let urls = ids.map { root.appendingPathComponent($0) }
        NSWorkspace.shared.recycle(urls) { [weak self] trashed, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil { self.show(Toast(text: "Couldn't move to Trash", symbol: "exclamationmark.triangle.fill")); return }
                for id in ids { self.sorter.index.delete(path: id) }
                withAnimation(.snappy(duration: 0.3)) {
                    self.shots.removeAll { ids.contains($0.id) }
                    self.selection.subtract(ids)
                    self.recompute()
                }
                let n = ids.count
                self.show(Toast(text: "Moved \(n == 1 ? "1 screenshot" : "\(n) screenshots") to the Trash", symbol: "trash.fill") { [weak self] in
                    guard let self else { return }
                    for (orig, inTrash) in trashed {
                        try? FileManager.default.moveItem(at: inTrash, to: orig)
                    }
                    self.reload()
                })
            }
        }
    }

    func resort(_ ids: [String]) {
        let sorter = self.sorter
        let urls = ids.map { root.appendingPathComponent($0) }
        sorter.queue.async { [weak self] in
            let results = sorter.sort(urls)
            DispatchQueue.main.async {
                guard let self else { return }
                let folders = Set(results.map(\.folder))
                self.show(Toast(text: folders.count == 1 ? "Auto-sorted into \(folders.first!)" : "Auto-sorted into \(folders.count) folders", symbol: "wand.and.stars"))
                self.reload()
            }
        }
    }

    func reveal(_ ids: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(ids.map { root.appendingPathComponent($0) })
    }

    func revealFolder(_ folder: String) {
        NSWorkspace.shared.open(folder.isEmpty ? root : root.appendingPathComponent(folder))
    }

    func copyText(_ ids: [String]) {
        let text = ids.map { sorter.index.text(forPath: $0) ?? "" }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(Toast(text: text.isEmpty ? "No text found to copy" : "Copied text", symbol: "doc.on.clipboard"))
    }

    func markOpened(_ id: String) {
        sorter.index.markOpened(path: id)
    }

    func showWindow() {
        openWindow?("main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Jump to a screenshot: show its folder and select it (and open it, if asked).
    func focus(_ id: String, open: Bool = false) {
        query = ""
        searchHits = nil
        scope = .folder((id as NSString).deletingLastPathComponent)
        if case .folder(let f) = scope, f.isEmpty { scope = .inbox }
        recompute()
        selection = [id]
        anchor = id
        if open, let shot = visible.first(where: { $0.id == id }) { self.open(shot) }
    }

    func copy(_ ids: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(ids.map { root.appendingPathComponent($0) as NSURL })
    }

    func createFolder(_ path: String) {
        let clean = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != ".." }.joined(separator: "/")
        guard !clean.isEmpty else { return }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(clean), withIntermediateDirectories: true)
        reload()
    }

    /// Files dropped on a sidebar folder: move ours (the whole selection if a selected one was dragged), copy outside files in.
    func drop(_ urls: [URL], on folder: String) -> Bool {
        let rootPath = root.path + "/"
        let ours = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { $0.path.hasPrefix(rootPath) }
        var ids = ours.map { sorter.relative($0) }
        if ids.contains(where: { selection.contains($0) }) { ids = Array(Set(ids).union(selection)) }
        if !ids.isEmpty { move(ids, to: folder) }
        let outside = urls.filter { !$0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath) && ShotFile.isImage($0) }
        if !outside.isEmpty {
            let target = root.appendingPathComponent(folder)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for u in outside { try? FileManager.default.copyItem(at: u, to: ShotFile.uniqueDestination(in: target, name: u.lastPathComponent)) }
            show(Toast(text: "Copied \(outside.count) image\(outside.count == 1 ? "" : "s") into \(folder)"))
            reload()
        }
        return !ids.isEmpty || !outside.isEmpty
    }

    func shuffle() {
        guard !visible.isEmpty else { return }
        withAnimation(.snappy(duration: 0.45)) {
            shuffled = visible.map(\.id).shuffled()
            recompute()
        }
    }

    func unshuffle() {
        withAnimation(.snappy(duration: 0.45)) { shuffled = nil; recompute() }
    }

    func show(_ toast: Toast) {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self.toast = toast }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.2)) { if self?.toast?.id == toast.id { self?.toast = nil } }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (toast.undo == nil ? 2.8 : 6), execute: work)
    }

    func text(for id: String) -> String {
        sorter.index.text(forPath: id) ?? ""
    }

    // MARK: viewer + triage

    func open(_ shot: Shot) {
        guard let i = visible.firstIndex(of: shot) else { return }
        viewer = visible
        viewerIndex = i
    }

    func startSlideshow() {
        guard !visible.isEmpty else { return }
        viewer = visible.shuffled()
        viewerIndex = 0
        slideshow = true
    }

    func closeViewer() {
        slideshow = false
        viewer = nil
    }

    func startTriage() {
        guard canTriage else { return }
        triage = visible
        triagePos = 0
    }

    var triageTargets: [String] {
        let tops = tree.map(\.id).filter { $0 != fallback }
        return Array(NSOrderedSet(array: recentFolders.filter { !$0.isEmpty && $0 != fallback } + tops).array.prefix(9)) as? [String] ?? []
    }

    // MARK: login item

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                show(Toast(text: "Couldn't change the login item. Add Shotshelf in System Settings > General > Login Items.", symbol: "exclamationmark.triangle.fill"))
            }
        }
    }
}
