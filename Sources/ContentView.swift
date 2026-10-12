import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var lib
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var lib = lib
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            GridView()
                .navigationTitle(lib.title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
                .searchable(text: $lib.query, placement: .toolbar, prompt: "Search text in screenshots")
        }
        .overlay {
            if lib.viewer != nil {
                PhotoViewer()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .overlay {
            if lib.triage != nil {
                TriageView()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: lib.viewer != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: lib.triage != nil)
        .sheet(item: $lib.moveRequest) { MovePalette(request: $0) }
        .sheet(isPresented: $lib.showWelcome) { WelcomeView() }
        .onAppear { lib.openWindow = { id in openWindow(id: id) } }
    }

    private var subtitle: String {
        let n = lib.visible.count
        return n == 1 ? "1 screenshot" : "\(n.formatted()) screenshots"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if lib.canTriage {
                Button { lib.startTriage() } label: { Label("Triage", systemImage: "rectangle.stack.badge.play") }
                    .help("Sort these one by one with number keys (T)")
            }
            Button { lib.shuffled == nil ? lib.shuffle() : lib.unshuffle() } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .help("Shuffle (S)")
            .symbolVariant(lib.shuffled == nil ? .none : .circle.fill)
            Button { lib.startSlideshow() } label: { Label("Slideshow", systemImage: "play.rectangle") }
                .help("Slideshow (P)")
            Menu {
                Picker("Order", selection: Binding(get: { lib.newestFirst }, set: { lib.newestFirst = $0 })) {
                    Text("Newest First").tag(true)
                    Text("Oldest First").tag(false)
                }
                .pickerStyle(.inline)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            .help("Sort order")
        }
        ToolbarItem(placement: .primaryAction) {
            Slider(value: Binding(get: { lib.thumbSize }, set: { lib.thumbSize = $0 }), in: 140...420)
                .frame(width: 96)
                .help("Thumbnail size")
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(Library.self) private var lib
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: Binding<Scope?>(get: { lib.scope }, set: { if let s = $0 { lib.scope = s; lib.query = "" } })) {
            Section("Library") {
                Label("All Screenshots", systemImage: "square.grid.2x2")
                    .badge(lib.shots.count)
                    .tag(Scope.all)
                FolderRow(path: lib.fallback, name: lib.fallback, count: lib.count(of: lib.fallback), highlight: true)
                    .tag(Scope.folder(lib.fallback))
                if lib.inboxCount > 0 {
                    Label("Waiting to Sort", systemImage: "tray.and.arrow.down")
                        .badge(lib.inboxCount)
                        .tag(Scope.inbox)
                }
            }
            Section("Folders") {
                OutlineGroup(lib.tree.filter { $0.id != lib.fallback }, children: \.children) { node in
                    FolderRow(path: node.id, name: node.name, count: node.total)
                        .tag(Scope.folder(node.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !lib.status.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(lib.status).font(.caption).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
                HStack(spacing: 14) {
                    Button {
                        lib.moveRequest = MoveRequest(ids: [], title: "New folder") { lib.createFolder($0) }
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .help("New folder (Shift-Command-N)")
                    Spacer()
                    Button { openWindow(id: "expenses") } label: { Image(systemName: "dollarsign.circle") }
                        .help("Expenses from your receipts (Shift-Command-E)")
                    Button { openWindow(id: "cleanup") } label: { Image(systemName: "sparkles") }
                        .help("Clean up duplicates and old screenshots (Shift-Command-K)")
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .animation(.easeOut, value: lib.status)
        }
    }
}

struct FolderRow: View {
    @Environment(Library.self) private var lib
    let path: String
    let name: String
    let count: Int
    var highlight = false
    @State private var targeted = false

    var body: some View {
        Label {
            Text(name).lineLimit(1)
        } icon: {
            Image(systemName: FolderRow.symbol(for: path))
                .foregroundStyle(path.contains("/") ? Color.secondary : FolderRow.tint(for: path))
        }
        .badge(highlight ? 0 : count)
        .overlay(alignment: .trailing) {
            if highlight && count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(targeted ? 0.25 : 0)).padding(-4))
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.spring(response: 0.25), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in lib.drop(urls, on: path) } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Show in Finder") { lib.revealFolder(path) }
            Button("New Folder Inside...") {
                lib.moveRequest = MoveRequest(ids: [], title: "New folder") { lib.createFolder($0) }
            }
        }
    }

    static func symbol(for path: String) -> String {
        switch path.split(separator: "/").first.map(String.init)?.lowercased() ?? "" {
        case "receipts": return "receipt"
        case "development": return "chevron.left.forwardslash.chevron.right"
        case "general": return "tray"
        case "ai chats": return "sparkles"
        case "chats & messages": return "bubble.left.and.bubble.right"
        case "finance": return "chart.line.uptrend.xyaxis"
        case "documents": return "doc.text"
        case "social": return "heart"
        case "travel": return "airplane"
        case "maps & places": return "mappin.and.ellipse"
        case "design & inspiration": return "paintpalette"
        case "school & learning": return "graduationcap"
        default: return "folder"
        }
    }

    static func tint(for path: String) -> Color {
        let palette: [Color] = [.indigo, .teal, .orange, .pink, .green, .blue, .purple, .mint, .red, .cyan, .yellow, .brown]
        let top = path.split(separator: "/").first.map(String.init) ?? path
        let h = top.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[h % palette.count]
    }
}

// MARK: - Toast

struct ToastView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        if let toast = lib.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.symbol).foregroundStyle(Color.accentColor)
                Text(toast.text).lineLimit(2)
                if let undo = toast.undo {
                    Button("Undo") {
                        undo()
                        withAnimation { lib.toast = nil }
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .keyboardShortcut("z", modifiers: .command)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
            .id(toast.id)
        }
    }
}
