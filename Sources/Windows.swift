import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ExpensesView: View {
    @Environment(Library.self) private var lib
    @Environment(\.openWindow) private var openWindow
    @State private var rows: [Expense] = []
    @State private var selection: Set<Expense.ID> = []
    @State private var sortOrder = [KeyPathComparator(\Expense.date, order: .reverse)]

    /// Totals per currency, most-used currency first; receipts in other currencies aren't mixed in.
    private var totals: [(currency: String, sum: Double)] {
        var sums: [String: (Double, Int)] = [:]
        for r in rows { if let a = r.amount { sums[r.currency, default: (0, 0)].0 += a; sums[r.currency, default: (0, 0)].1 += 1 } }
        return sums.sorted { $0.value.1 > $1.value.1 }.map { ($0.key, $0.value.0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Expenses").font(.title2.weight(.bold))
                    Text("From \(rows.count) receipt screenshots in Receipts").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(Array(totals.enumerated()), id: \.offset) { i, t in
                        Text(t.currency + t.sum.formatted(.number.precision(.fractionLength(2))))
                            .font(i == 0 ? .title2.weight(.semibold).monospacedDigit() : .callout.monospacedDigit())
                            .foregroundStyle(i == 0 ? .primary : .secondary)
                    }
                    Text("total found").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Date", value: \.date) { Text($0.date.formatted(date: .abbreviated, time: .omitted)) }
                    .width(min: 90, ideal: 110)
                TableColumn("Merchant", value: \.merchant)
                TableColumn("Category", value: \.category)
                TableColumn("Amount") { e in
                    Text(e.formattedAmount)
                        .monospacedDigit()
                        .foregroundStyle(e.amount == nil ? .tertiary : .primary)
                }
                .width(min: 80, ideal: 100)
            }
            .contextMenu(forSelectionType: Expense.ID.self) { ids in
                Button("Show Screenshot") { if let id = ids.first { lib.focus(id); openWindow(id: "main") } }
                Button("Show in Finder") { lib.reveal(Array(ids)) }
            } primaryAction: { ids in
                if let id = ids.first { lib.focus(id); openWindow(id: "main") }
            }
            .onChange(of: sortOrder) { _, order in rows.sort(using: order) }
            HStack {
                Text("Amounts are read from the text on each receipt. Double-click a row to open it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV...") { exportCSV() }
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 420)
        .task(id: lib.shots.count) { await load() }
    }

    private func load() async {
        let receipts = lib.shots.filter { $0.folder == "Receipts" || $0.folder.hasPrefix("Receipts/") }
        let index = lib.sorter.index
        let parsed = await Task.detached(priority: .userInitiated) {
            // An exact duplicate of a receipt is the same expense; count it once.
            let hashes = Dictionary(index.entries().compactMap { e in e.hash.map { (e.path, $0) } }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            let unique = receipts.filter { s in hashes[s.id].map { seen.insert($0).inserted } ?? true }
            return unique.map { ReceiptParser.expense(path: $0.id, text: index.text(forPath: $0.id) ?? "", taken: $0.date) }
        }.value
        withAnimation { rows = parsed.sorted(using: sortOrder) }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Shotshelf Expenses.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        var csv = "Date,Merchant,Category,Amount,Currency,Screenshot\n"
        for r in rows {
            csv += [iso.string(from: r.date), q(r.merchant), q(r.category), r.amount.map { String(format: "%.2f", $0) } ?? "", r.currency, q(r.id)].joined(separator: ",") + "\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Clean up

struct CleanupView: View {
    @Environment(Library.self) private var lib
    @State private var mode = Mode.duplicates
    @State private var groups: [[Shot]] = []
    @State private var marked: Set<String> = []
    @State private var loading = true
    @State private var days = 30

    enum Mode: String, CaseIterable, Identifiable {
        case duplicates = "Exact Duplicates", lookalikes = "Look-alikes", stale = "Old in General"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 460)
                Text(explanation).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if mode == .stale {
                    Stepper("Older than \(days) days", value: $days, in: 7...365, step: 7)
                        .fixedSize()
                }
            }
            .padding(16)
            Divider()
            ZStack {
                if loading {
                    ProgressView("Looking...")
                } else if groups.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 40, weight: .light)).foregroundStyle(Color.accentColor.gradient)
                        Text("Nothing to clean up here").font(.title3.weight(.semibold))
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                                    ForEach(group) { shot in cell(shot) }
                                }
                                if mode != .stale { Divider() }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Select All") { marked = Set(groups.flatMap { $0 }.map(\.id)) }
                Button("Select None") { marked = [] }
                Spacer()
                Text("\(marked.count) selected").foregroundStyle(.secondary)
                Button("Move to Trash") {
                    lib.trash(Array(marked))
                    let gone = marked
                    withAnimation { groups = groups.map { $0.filter { !gone.contains($0.id) } }.filter { mode == .stale ? !$0.isEmpty : $0.count > 1 } }
                    marked = []
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(marked.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 680, minHeight: 480)
        .task(id: "\(mode.rawValue)-\(days)") { await load() }
    }

    private var explanation: String {
        switch mode {
        case .duplicates: return "Identical files. All but the newest copy in each group are selected."
        case .lookalikes: return "Screenshots that look almost the same, like several shots of one page. The newest stays unselected."
        case .stale: return "Screenshots in \(lib.fallback) older than \(days) days that you have never opened in Shotshelf. Review, then select what to remove."
        }
    }

    private func cell(_ shot: Shot) -> some View {
        let on = marked.contains(shot.id)
        return VStack(alignment: .leading, spacing: 4) {
            Color.clear.aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .top) { Thumbnail(url: shot.url, size: 400) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.red : .primary.opacity(0.1), lineWidth: on ? 3 : 1))
                .overlay(alignment: .topLeading) {
                    Image(systemName: on ? "trash.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, on ? Color.red : Color.black.opacity(0.3))
                        .padding(6)
                }
            Text(shot.folder.isEmpty ? shot.name : shot.folder).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Text(shot.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { if on { marked.remove(shot.id) } else { marked.insert(shot.id) } }
        .animation(.spring(response: 0.25), value: on)
    }

    /// Pages that look alike but say different things (two articles on one site) aren't duplicates.
    nonisolated private static func wordSet(_ text: String?) -> Set<Substring> {
        Set((text ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }))
    }

    private func load() async {
        loading = true
        let shots = lib.shots
        let entries = lib.sorter.index.entries()
        let mode = self.mode, days = self.days, fallback = lib.fallback
        let found: [[Shot]] = await Task.detached(priority: .userInitiated) {
            let byPath = Dictionary(shots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let live = entries.filter { byPath[$0.path] != nil }
            func sameWords(_ x: String?, _ y: String?) -> Bool {
                guard (x?.count ?? 0) > 60, (y?.count ?? 0) > 60 else { return true }
                let a = CleanupView.wordSet(x), b = CleanupView.wordSet(y)
                return Double(a.intersection(b).count) / Double(max(1, a.union(b).count)) >= 0.3
            }
            switch mode {
            case .duplicates:
                let groups = Dictionary(grouping: live.filter { $0.hash != nil }, by: { $0.hash! }).values.filter { $0.count > 1 }
                return groups.map { $0.compactMap { byPath[$0.path] }.sorted { $0.date > $1.date } }.sorted { $0[0].date > $1[0].date }
            case .lookalikes:
                let items = live.filter { $0.phash != nil }
                var parent = Array(items.indices)
                func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
                for i in items.indices {
                    for j in (i + 1)..<items.count where items[i].hash != items[j].hash {
                        if Vision2.distance(items[i].phash!, items[j].phash!) <= 3 && sameWords(items[i].text, items[j].text) {
                            parent[find(i)] = find(j)
                        }
                    }
                }
                let groups = Dictionary(grouping: items.indices, by: find).values.filter { $0.count > 1 }
                return groups.map { $0.compactMap { byPath[items[$0].path] }.sorted { $0.date > $1.date } }.sorted { $0[0].date > $1[0].date }
            case .stale:
                let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
                let stale = live.filter { $0.opened == nil }.compactMap { byPath[$0.path] }
                    .filter { $0.folder == fallback && $0.date < cutoff }
                    .sorted { $0.date > $1.date }
                return stale.isEmpty ? [] : [stale]
            }
        }.value
        groups = found
        marked = mode == .stale ? [] : Set(found.flatMap { $0.dropFirst() }.map(\.id))
        loading = false
    }
}
