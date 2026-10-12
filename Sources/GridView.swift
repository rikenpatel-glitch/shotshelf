import SwiftUI

struct GridView: View {
    @Environment(Library.self) private var lib
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            if lib.loaded && lib.visible.isEmpty {
                EmptyState()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: lib.thumbSize, maximum: lib.thumbSize * 1.7), spacing: 14)],
                          alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(lib.groups) { group in
                        Section {
                            ForEach(group.shots) { shot in
                                ShotCell(shot: shot, showFolder: lib.isSearching || lib.scope == .all)
                            }
                        } header: {
                            GroupHeader(title: String(group.id.split(separator: "-").dropLast().joined(separator: "-")), count: group.shots.count)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { lib.selection = [] }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: lib.viewer == nil && lib.triage == nil) { _, idle in if idle { focused = true } }
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let sel = Array(lib.selection)
        if press.modifiers.contains(.command) {
            if press.characters == "a" { lib.selectAll(); return .handled }
            return .ignored
        }
        switch press.key {
        case .space, .return:
            if let s = lib.selectedShots.first ?? lib.visible.first { lib.open(s) }
            return .handled
        case .escape:
            lib.selection = []
            return .handled
        case .delete, .deleteForward:
            if !sel.isEmpty { lib.trash(sel) }
            return .handled
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            step(press.key)
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "m": if !sel.isEmpty { lib.moveRequest = MoveRequest(ids: sel) }
        case "t": lib.startTriage()
        case "s": lib.shuffled == nil ? lib.shuffle() : lib.unshuffle()
        case "p": lib.startSlideshow()
        case "r": if !sel.isEmpty { lib.resort(sel) }
        default: return .ignored
        }
        return .handled
    }

    /// Arrow keys move the selection; up/down jump roughly one row.
    private func step(_ key: KeyEquivalent) {
        guard !lib.visible.isEmpty else { return }
        let current = lib.anchor.flatMap { id in lib.visible.firstIndex { $0.id == id } } ?? -1
        let perRow = max(1, Int((NSApp.keyWindow?.frame.width ?? 1200) - 290) / Int(lib.thumbSize + 14))
        let delta = key == .leftArrow ? -1 : key == .rightArrow ? 1 : key == .upArrow ? -perRow : perRow
        let next = min(max(0, current + delta), lib.visible.count - 1)
        let id = lib.visible[next].id
        lib.selection = [id]
        lib.anchor = id
    }
}

struct GroupHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.headline)
            Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }
}

struct ShotCell: View {
    @Environment(Library.self) private var lib
    let shot: Shot
    var showFolder = false
    @State private var hover = false

    private var selected: Bool { lib.selection.contains(shot.id) }

    var body: some View {
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .top) { Thumbnail(url: shot.url, size: lib.thumbSize > 280 ? 760 : 520) }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomLeading) { if hover { info } }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 1)
            }
            .overlay(alignment: .topLeading) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(7)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(selected ? 0.965 : hover ? 1.02 : 1)
            .shadow(color: .black.opacity(hover ? 0.22 : 0), radius: 14, y: 7)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hover)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: selected)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture {
                if NSApp.currentEvent?.clickCount == 2 { lib.open(shot) } else { lib.click(shot) }
            }
            .draggable(shot.url) {
                Thumbnail(url: shot.url, size: 320)
                    .frame(width: 160, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        if lib.selection.count > 1 && selected {
                            Text("\(lib.selection.count)")
                                .font(.caption.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor))
                                .padding(4)
                        }
                    }
            }
            .contextMenu { menu }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(shot.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(shot.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).opacity(0.8)
            if showFolder && !shot.folder.isEmpty {
                Text(shot.folder).font(.caption2.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.white.opacity(0.18), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    @ViewBuilder
    private var menu: some View {
        let ids = selected ? Array(lib.selection) : [shot.id]
        Button("Open") { lib.open(shot) }
        Button(ids.count > 1 ? "Move \(ids.count) to Folder..." : "Move to Folder...") { lib.moveRequest = MoveRequest(ids: ids) }
        Button("Auto-Sort Again") { lib.resort(ids) }
        Divider()
        Button("Copy") { lib.copy(ids) }
        Button("Copy Text") { lib.copyText(ids) }
        Button("Show in Finder") { lib.reveal(ids) }
        Divider()
        Button("Move to Trash", role: .destructive) { lib.trash(ids) }
    }
}

struct EmptyState: View {
    @Environment(Library.self) private var lib

    var body: some View {
        let (symbol, title, message): (String, String, String) =
            lib.isSearching ? ("magnifyingglass", "No matches", "Search looks at the words inside every screenshot. Try different words.")
            : lib.scope == .folder(lib.fallback) ? ("checkmark.seal", "All sorted", "Screenshots the sorter can't place land here, ready for triage.")
            : ("photo.on.rectangle.angled", "Nothing here yet", "Drag screenshots onto this folder in the sidebar, or use Move to Folder.")
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Color.accentColor.gradient)
                .symbolEffect(.bounce, value: lib.scope)
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .transition(.opacity)
    }
}
