import SwiftUI

struct PhotoViewer: View {
    @Environment(Library.self) private var lib
    @FocusState private var focused: Bool
    @State private var showText = false
    @State private var text = ""
    @State private var direction: CGFloat = 1
    @State private var tick = 0

    private let interval: TimeInterval = 3.5
    private var list: [Shot] { lib.viewer ?? [] }
    private var shot: Shot? { list.indices.contains(lib.viewerIndex) ? list[lib.viewerIndex] : nil }

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.9)).ignoresSafeArea()
                .onTapGesture { lib.closeViewer() }
            if let shot {
                VStack(spacing: 0) {
                    topBar(shot)
                    HStack(spacing: 0) {
                        stage(shot)
                        if showText {
                            textPanel.transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    filmstrip
                }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { handle($0) }
        .task(id: lib.viewerIndex) {
            if let id = shot?.id { lib.markOpened(id) }
            await loadText()
        }
        .task(id: lib.slideshow ? tick : -1) {
            guard lib.slideshow else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, lib.slideshow else { return }
            go(1)
            tick += 1
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showText)
    }

    private func topBar(_ shot: Shot) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shot.name).font(.headline).lineLimit(1)
                Text("\(shot.date.formatted(date: .abbreviated, time: .shortened))  ·  \(shot.folder.isEmpty ? "Inbox" : shot.folder)  ·  \(lib.viewerIndex + 1) of \(list.count)")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            barButton(lib.slideshow ? "pause.fill" : "play.fill", "Slideshow (Space)") { lib.slideshow.toggle(); tick += 1 }
            barButton("shuffle", "Shuffle (S)") { shuffle() }
            barButton("text.viewfinder", "Show text (T)", on: showText) { showText.toggle() }
            barButton("doc.on.clipboard", "Copy text (C)") { lib.copyText([shot.id]) }
            barButton("folder", "Move (M)") { move(shot) }
            barButton("magnifyingglass", "Show in Finder") { lib.reveal([shot.id]) }
            barButton("trash", "Move to Trash (Delete)") { trash(shot) }
            barButton("xmark", "Close (Esc)") { lib.closeViewer() }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .overlay(alignment: .top) {
            if lib.slideshow {
                ProgressBar(duration: interval, tick: tick)
            }
        }
    }

    private func barButton(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.6) : .white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func stage(_ shot: Shot) -> some View {
        ZStack {
            FullImage(url: shot.url)
                .id(shot.id)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 40 * direction)),
                                        removal: .opacity.combined(with: .offset(x: -40 * direction))))
                .padding(.horizontal, 70)
                .padding(.vertical, 14)
            HStack {
                navButton("chevron.left") { go(-1) }
                Spacer()
                navButton("chevron.right") { go(1) }
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: shot.id)
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private var textPanel: some View {
        ScrollView {
            Text(text.isEmpty ? "No text found in this screenshot." : text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(width: 340)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.trailing, 14)
        .padding(.vertical, 14)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                        Thumbnail(url: s.url, size: 200)
                            .frame(width: 76, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: i == lib.viewerIndex ? 2 : 0))
                            .opacity(i == lib.viewerIndex ? 1 : 0.45)
                            .offset(y: i == lib.viewerIndex ? -3 : 0)
                            .id(s.id)
                            .onTapGesture { direction = i > lib.viewerIndex ? 1 : -1; lib.viewerIndex = i }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(height: 76)
            .onChange(of: lib.viewerIndex, initial: true) { _, _ in
                if let id = shot?.id { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .animation(.spring(response: 0.3), value: lib.viewerIndex)
    }

    // MARK: actions

    private func go(_ delta: Int) {
        guard !list.isEmpty else { return }
        direction = delta >= 0 ? 1 : -1
        lib.viewerIndex = (lib.viewerIndex + delta + list.count) % list.count
    }

    private func shuffle() {
        guard let current = shot else { return }
        lib.viewer = [current] + list.filter { $0.id != current.id }.shuffled()
        lib.viewerIndex = 0
        lib.show(Toast(text: "Shuffled", symbol: "shuffle"))
    }

    private func removeCurrent() {
        guard var l = lib.viewer else { return }
        l.remove(at: lib.viewerIndex)
        if l.isEmpty { lib.closeViewer(); return }
        lib.viewer = l
        lib.viewerIndex = min(lib.viewerIndex, l.count - 1)
    }

    private func move(_ shot: Shot) {
        lib.moveRequest = MoveRequest(ids: [shot.id]) { folder in
            lib.move([shot.id], to: folder)
            removeCurrent()
        }
    }

    private func trash(_ shot: Shot) {
        lib.trash([shot.id])
        removeCurrent()
    }

    private func loadText() async {
        guard let id = shot?.id else { return }
        let lib = self.lib
        text = await Task.detached { await MainActor.run { lib.text(for: id) } }.value
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard let shot else { return .ignored }
        switch press.key {
        case .escape: lib.closeViewer()
        case .rightArrow: go(1); tick += 1
        case .leftArrow: go(-1); tick += 1
        case .space: lib.slideshow.toggle(); tick += 1
        case .delete, .deleteForward: trash(shot)
        default:
            switch press.characters.lowercased() {
            case "t": showText.toggle()
            case "c": lib.copyText([shot.id])
            case "s": shuffle()
            case "m": move(shot)
            case "p": lib.slideshow.toggle(); tick += 1
            default: return .ignored
            }
        }
        return .handled
    }
}

/// Full-resolution image, decoded off the main thread.
struct FullImage: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            } else {
                Thumbnail(url: url, size: 520, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .task(id: url) { image = await ThumbnailStore.shared.image(url, size: 3200) }
    }
}

struct ProgressBar: View {
    let duration: TimeInterval
    let tick: Int
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(LinearGradient(colors: [.indigo, .cyan], startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * progress, height: 2)
        }
        .frame(height: 2)
        .onAppear { restart() }
        .onChange(of: tick) { _, _ in restart() }
    }

    private func restart() {
        progress = 0
        withAnimation(.linear(duration: duration)) { progress = 1 }
    }
}
