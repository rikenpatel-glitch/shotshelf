import SwiftUI

/// One screenshot at a time: press 1-9 to send it to a folder.
struct TriageView: View {
    @Environment(Library.self) private var lib
    @FocusState private var focused: Bool
    @State private var history: [(shot: Shot, moved: (String, String))] = []
    @State private var fly: CGSize = .zero
    @State private var flying = false
    @State private var hit: String?
    @State private var targets: [String] = []

    private var items: [Shot] { lib.triage ?? [] }
    private var current: Shot? { items.indices.contains(lib.triagePos) ? items[lib.triagePos] : nil }

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.92)).ignoresSafeArea()
            VStack(spacing: 18) {
                header
                GeometryReader { geo in
                    ZStack {
                        if let next = items.indices.contains(lib.triagePos + 1) ? items[lib.triagePos + 1] : nil {
                            card(next).scaleEffect(0.93).offset(y: 18).opacity(0.35).blur(radius: 1)
                        }
                        if let current {
                            card(current)
                                .id(current.id)
                                .offset(fly)
                                .scaleEffect(flying ? 0.25 : 1)
                                .rotationEffect(.degrees(flying ? Double(fly.width / 40) : 0))
                                .opacity(flying ? 0 : 1)
                                .transition(.asymmetric(insertion: .scale(scale: 0.93).combined(with: .opacity).combined(with: .offset(y: 18)), removal: .identity))
                        } else {
                            done
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                hints
                targetBar
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            targets = lib.triageTargets
        }
        .onKeyPress(phases: .down) { handle($0) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Triage").font(.title2.weight(.bold))
            Text("\(max(0, items.count - lib.triagePos)) left").foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(history.isEmpty)
            Button { skip() } label: { Label("Skip", systemImage: "forward.end") }
                .disabled(current == nil)
            Button { close() } label: { Image(systemName: "xmark") }
        }
        .buttonStyle(.bordered)
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.1)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: [.indigo, .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * (items.isEmpty ? 1 : CGFloat(lib.triagePos) / CGFloat(items.count)), height: 3)
                            .animation(.spring(response: 0.4), value: lib.triagePos)
                    }
            }
            .frame(height: 3)
            .offset(y: 16)
        }
    }

    private func card(_ shot: Shot) -> some View {
        FullImage(url: shot.url)
            .frame(maxWidth: 1100)
    }

    private var done: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 36, weight: .bold))
                .frame(width: 84, height: 84)
                .background(Circle().fill(LinearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: .indigo.opacity(0.7), radius: 24, y: 10)
                .symbolEffect(.bounce, value: current == nil)
            Text("All caught up").font(.title.weight(.bold))
            Text("Every screenshot here has a home.").foregroundStyle(.white.opacity(0.6))
            Button("Done") { close() }.buttonStyle(.borderedProminent).padding(.top, 6)
        }
        .transition(.scale.combined(with: .opacity))
    }

    private var hints: some View {
        HStack(spacing: 18) {
            hint("1-9", "send")
            hint("/", "any folder")
            hint("Space", "skip")
            hint("Z", "undo")
            hint("Esc", "done")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.55))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.25)))
            Text(label)
        }
    }

    private var targetBar: some View {
        FlowRow(spacing: 8) {
            ForEach(Array(targets.enumerated()), id: \.element) { i, folder in
                targetButton(key: "\(i + 1)", folder: folder, symbol: FolderRow.symbol(for: folder)) { send(to: folder) }
            }
            targetButton(key: "/", folder: "Other folder...", symbol: "magnifyingglass") { pickOther() }
        }
        .frame(maxWidth: 1100)
    }

    private func targetButton(key: String, folder: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(key).font(.caption.monospaced().weight(.bold))
                    .frame(minWidth: 18)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.14)))
                Image(systemName: symbol).font(.system(size: 13))
                Text(folder).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 11).fill(hit == folder ? Color.accentColor : .white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.12)))
            .scaleEffect(hit == folder ? 1.07 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hit)
    }

    // MARK: actions

    private func send(to folder: String) {
        guard let shot = current, !flying else { return }
        hit = folder
        let index = targets.firstIndex(of: folder) ?? targets.count
        let spread = CGFloat(index) - CGFloat(targets.count) / 2
        withAnimation(.easeIn(duration: 0.32)) {
            fly = CGSize(width: spread * 110, height: 420)
            flying = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let moved = lib.move([shot.id], to: folder, announce: false)
            if let m = moved.first { history.append((shot, (m.old, m.new))) }
            if !targets.contains(folder) { targets = Array(([folder] + targets).prefix(9)) }
            fly = .zero
            flying = false
            hit = nil
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { lib.triagePos += 1 }
        }
    }

    private func skip() {
        guard current != nil else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { lib.triagePos += 1 }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        lib.undoMoves([last.moved])
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { lib.triagePos = max(0, lib.triagePos - 1) }
    }

    private func pickOther() {
        guard let shot = current else { return }
        lib.moveRequest = MoveRequest(ids: [shot.id]) { folder in send(to: folder) }
    }

    private func close() {
        lib.triage = nil
        lib.reload()
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard lib.moveRequest == nil else { return .ignored }
        switch press.key {
        case .escape: close(); return .handled
        case .space: skip(); return .handled
        default: break
        }
        let c = press.characters.lowercased()
        if let n = Int(c), n >= 1, n <= targets.count { send(to: targets[n - 1]); return .handled }
        if c == "/" { pickOther(); return .handled }
        if c == "z" { undo(); return .handled }
        return .ignored
    }
}

/// Lays children out left to right, wrapping onto new centered lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += row.items.isEmpty ? size.width : size.width + spacing
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
