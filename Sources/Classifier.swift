import Foundation

/// Picks a folder for a screenshot from its recognized text, using keyword rules.
///
/// Every rule is scored: +1 per keyword, +3 per strong keyword, a bonus when a project
/// name matches, +1 for a known merchant. Receipt rules only apply when the text looks
/// like a receipt. The best score at or above the rule's minimum wins; otherwise the
/// screenshot goes to the fallback folder.
final class Classifier {
    private struct Gate { let patterns: [NSRegularExpression]; let min: Int; let money: Bool }

    private struct Rule {
        let folder: String
        let requires: String?
        let min: Int
        let needStrong: Bool
        let unless: [NSRegularExpression]
        let keywords: [(String, NSRegularExpression)]
        let strong: [(String, NSRegularExpression)]
        let merchants: [(String, NSRegularExpression)]
        let labels: Set<String>
        let apps: Set<String>
        let maxText: Int?
    }

    struct Scored { let score: Int; let folder: String; let hits: [String] }

    private static let projectMarkers = ["package.json", ".git", "pyproject.toml", "requirements.txt", "Cargo.toml",
                                         "go.mod", "pubspec.yaml", "Gemfile", "pom.xml", "build.gradle", "Package.swift"]
    private static let projectStopwords: Set<String> = [
        "app", "apps", "src", "lib", "docs", "files", "work", "test", "tests", "demo", "demos", "data", "web", "site",
        "website", "api", "server", "client", "clients", "mobile", "backend", "frontend", "archive", "backups", "extra",
        "research", "scripts", "tools", "temp", "tmp", "misc", "notes", "projects", "assets",
    ]
    private static let money = try! NSRegularExpression(
        pattern: "[$€£₹]\\s?\\d[\\d,]*\\.\\d{2}|\\d[\\d,]*\\.\\d{2}\\s?(usd|eur|gbp|inr)", options: .caseInsensitive)
    private static let nonAlnum = try! NSRegularExpression(pattern: "[^a-z0-9]+")

    let fallback: String
    private let gates: [String: Gate]
    private var rules: [Rule] = []
    private var projects: [(String, [NSRegularExpression])] = []
    private var boilerplate: Set<String> = []

    init(config: AppConfig, index: IndexDB?) {
        fallback = config.fallback
        var g: [String: Gate] = [:]
        for (name, spec) in config.gates {
            g[name] = Gate(patterns: (spec["keywords"] as? [String] ?? []).map(Classifier.pattern),
                           min: spec["min"] as? Int ?? 1,
                           money: spec["money"] as? Bool ?? false)
        }
        gates = g
        for r in config.rules {
            guard let folder = r["folder"] as? String else { continue }
            rules.append(Rule(
                folder: folder,
                requires: r["requires"] as? String,
                min: r["min_score"] as? Int ?? 2,
                needStrong: r["require_strong"] as? Bool ?? false,
                unless: (r["unless"] as? [String] ?? []).map(Classifier.pattern),
                keywords: (r["keywords"] as? [String] ?? []).map { ($0, Classifier.pattern($0)) },
                strong: (r["strong"] as? [String] ?? []).map { ($0, Classifier.pattern($0)) },
                merchants: Classifier.merchants(for: r, root: config.root),
                labels: Set((r["labels"] as? [String] ?? []).map { $0.lowercased() }),
                apps: Set((r["apps"] as? [String] ?? []).map { $0.lowercased() }),
                maxText: r["max_text"] as? Int))
        }
        projects = Classifier.discoverProjects(config: config, rules: config.rules)
        if let index {
            let texts = index.allTexts()
            boilerplate = Classifier.learnBoilerplate(texts)
            learner = Learner(examples: index.manualExamples(), allTexts: texts, fallback: fallback)
        }
    }

    private var learner: Learner?

    private static let menuBar = try! NSRegularExpression(
        pattern: "^[^A-Za-z]{0,3}([A-Za-z][\\w.+ -]{1,24}?)\\s+(?:File|Shell|Edit)\\s+(?:Edit|View|Shell|Session|Selection|Format|Insert)\\b")

    /// The frontmost app, read from the macOS menu bar at the top of a full-screen screenshot.
    static func appName(_ text: String) -> String? {
        // Vision sometimes reads the menu bar as separate pieces ("Figma", "File", "Edit View"), so also try them joined.
        let top = text.split(separator: "\n").prefix(6).map(String.init)
        for l in top.prefix(4) + [top.joined(separator: " ")] {
            if let m = menuBar.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let r = Range(m.range(at: 1), in: l) {
                return l[r].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: matching helpers

    static func pattern(_ word: String) -> NSRegularExpression {
        let w = NSRegularExpression.escapedPattern(for: word.lowercased())
        let left = word.first.map { $0.isLetter || $0.isNumber } == true ? "(?<![a-z0-9])" : ""
        let right = word.last.map { $0.isLetter || $0.isNumber } == true ? "(?![a-z0-9])" : ""
        return try! NSRegularExpression(pattern: left + w + right)
    }

    static func normLine(_ line: String) -> String {
        let lower = line.lowercased()
        let replaced = nonAlnum.stringByReplacingMatches(in: lower, range: NSRange(lower.startIndex..., in: lower), withTemplate: " ")
        return replaced.split(separator: " ").joined(separator: " ")
    }

    private static func base(_ folder: String) -> String {
        folder.components(separatedBy: "/{").first ?? folder
    }

    /// Known merchants, plus any subfolder you created under the rule's folder.
    private static func merchants(for rule: [String: Any], root: URL) -> [(String, NSRegularExpression)] {
        guard let folder = rule["folder"] as? String, folder.contains("{merchant}") else { return [] }
        var names = rule["merchants"] as? [String] ?? []
        let dir = root.appendingPathComponent(base(folder))
        if let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            names += kids.filter { $0.hasDirectoryPath }.map { $0.lastPathComponent }
        }
        var seen = Set<String>()
        return names.compactMap { n in
            guard n.count >= 3, seen.insert(n.lowercased()).inserted else { return nil }
            return (n, pattern(n))
        }
    }

    /// Project folders found in projects_dirs, matched by their name appearing in a screenshot.
    private static func discoverProjects(config: AppConfig, rules: [[String: Any]]) -> [(String, [NSRegularExpression])] {
        let fm = FileManager.default
        let skip = config.projectIgnore
        let generic = projectStopwords.union(config.projectGeneric)
        var found: [(String, [NSRegularExpression])] = []

        func subdirs(_ d: URL) -> [URL] {
            let kids = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
            return kids.filter { $0.hasDirectoryPath && !skip.contains($0.lastPathComponent.lowercased()) && $0.lastPathComponent != "node_modules" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func hasMarker(_ d: URL) -> Bool { projectMarkers.contains { fm.fileExists(atPath: d.appendingPathComponent($0).path) } }
        func isProject(_ d: URL, depth: Int = 1) -> Bool { hasMarker(d) || (depth > 0 && subdirs(d).contains { isProject($0, depth: depth - 1) }) }
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        func add(_ rel: String) {
            let name = (rel as NSString).lastPathComponent.lowercased()
            let variants = Set([name,
                                name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "),
                                name.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")])
                .filter { $0.count >= 4 && !generic.contains($0) }
            if !variants.isEmpty { found.append((rel, variants.sorted().map(pattern))) }
        }

        for base in config.projectsDirs where fm.fileExists(atPath: base.path) {
            for d in subdirs(base) {
                if hasMarker(d) { add(d.lastPathComponent); continue }
                let children = subdirs(d).filter { isProject($0) }
                guard !children.isEmpty else { continue }
                // A generic parent like "apps" or "clients" is just a shelf: use child names directly.
                let group = !generic.contains(d.lastPathComponent.lowercased())
                if group { add(d.lastPathComponent) }
                for c in children {
                    if group && squash(c.lastPathComponent) == squash(d.lastPathComponent) { continue }
                    add(group ? "\(d.lastPathComponent)/\(c.lastPathComponent)" : c.lastPathComponent)
                }
            }
        }
        if let dev = rules.first(where: { ($0["folder"] as? String)?.contains("{project}") == true }),
           let folder = dev["folder"] as? String {
            let devRoot = config.root.appendingPathComponent(base(folder))
            let known = Set(found.map { $0.0.lowercased() })
            if let e = fm.enumerator(at: devRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
                for case let d as URL in e where d.hasDirectoryPath {
                    let rel = String(d.path.dropFirst(devRoot.path.count + 1))
                    if !known.contains(rel.lowercased()) { add(rel) }
                }
            }
        }
        return found
    }

    /// Browser bookmark-bar lines, learned from your own screenshots.
    ///
    /// A line counts as clutter when it repeats across many screenshots and almost always appears
    /// next to the browser's "Bookmarks" menu. Those lines are ignored when matching project and
    /// merchant names, so a bookmark called "my-project" doesn't pull every browser screenshot into
    /// that project, while an app's own logo (which also appears outside the browser) still counts.
    private static func learnBoilerplate(_ texts: [String]) -> Set<String> {
        var total: [String: Int] = [:], inBrowser: [String: Int] = [:]
        for text in texts {
            let lines = Set(text.split(separator: "\n").map { normLine(String($0)) }).subtracting([""])
            let browser = lines.contains { $0.contains("bookmarks") }
            for l in lines {
                total[l, default: 0] += 1
                if browser { inBrowser[l, default: 0] += 1 }
            }
        }
        let threshold = max(8, Int(Double(texts.count) * 0.02))
        return Set(total.filter { $0.value >= threshold && Double(inBrowser[$0.key] ?? 0) >= 0.9 * Double($0.value) }.keys)
    }

    private func matchProject(_ text: String) -> (String, Int)? {
        var best: (String, Int)?
        for (rel, pats) in projects {
            let hits = pats.reduce(0) { $0 + $1.count(in: text) }
            guard hits > 0 else { continue }
            let depth = rel.filter { $0 == "/" }.count
            if let b = best {
                let bDepth = b.0.filter { $0 == "/" }.count
                if (depth, hits) > (bDepth, b.1) { best = (rel, hits) }
            } else {
                best = (rel, hits)
            }
        }
        return best
    }

    // MARK: classify

    func classify(_ text: String, labels: String? = nil) -> String { ranked(text, labels: labels).first?.folder ?? fallback }

    func ranked(_ text: String, labels: String? = nil) -> [Scored] {
        let imageLabels = Analysis.parse(labels).filter { $0.value >= 0.5 }
        let app = Classifier.appName(text)?.lowercased()
        let t = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let names = text.split(separator: "\n")
            .filter { !boilerplate.contains(Classifier.normLine(String($0))) }
            .map { $0.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .joined(separator: " ")
        var gateOK: [String: Bool] = [:]
        for (name, g) in gates {
            let hits = g.patterns.filter { $0.matches(t) }.count
            gateOK[name] = hits >= g.min && (!g.money || Classifier.money.matches(t))
        }
        let project = matchProject(names)
        var scored: [(Int, Int, String, [String])] = []
        for (order, r) in rules.enumerated() {
            if let req = r.requires, gateOK[req] != true { continue }
            if let max = r.maxText, t.count > max { continue }
            var hits = r.keywords.filter { $0.1.matches(t) }.map { $0.0 }
            let labelHits = r.labels.intersection(imageLabels.keys)
            if !r.labels.isEmpty && !labelHits.isEmpty { hits += labelHits.sorted().map { "image: \($0)" } }
            let strong = r.strong.filter { $0.1.matches(t) }.map { $0.0 }
            if r.needStrong && strong.isEmpty { continue }
            if r.unless.contains(where: { $0.matches(t) }) { continue }
            var score = hits.count + 3 * strong.count + (r.requires != nil ? 2 : 0) + labelHits.count
            if let app, r.apps.contains(app) {
                score += 3
                hits.append("app: \(app)")
            }
            var folder = r.folder
            if folder.contains("{project}") {
                if let (name, n) = project {
                    score += 5 + min(n, 3)
                    folder = folder.replacingOccurrences(of: "{project}", with: name)
                } else {
                    folder = folder.replacingOccurrences(of: "/{project}", with: "/Other")
                }
            }
            if folder.contains("{merchant}") {
                if let m = r.merchants.first(where: { $0.1.matches(names) }) {
                    score += 1
                    folder = folder.replacingOccurrences(of: "{merchant}", with: m.0)
                } else {
                    folder = folder.replacingOccurrences(of: "/{merchant}", with: "")
                }
            }
            if score >= r.min { scored.append((score, order, folder, hits + strong)) }
        }
        // Screenshots that look like ones you filed by hand go to the same place.
        if let learned = learner?.nearest(text) {
            scored.append((learned.score, -1, learned.folder, ["looks like \(learned.example)"]))
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        return scored.map { Scored(score: $0.0, folder: $0.2, hits: $0.3) }
    }
}

extension NSRegularExpression {
    func matches(_ s: String) -> Bool {
        firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    func count(in s: String) -> Int {
        numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }
}

/// Learns from screenshots you moved by hand: a new screenshot whose words closely match one of
/// those goes to the same folder. Uses TF-IDF cosine similarity, so rare shared words count most.
final class Learner {
    private struct Example { let folder: String; let name: String; let vector: [String: Double] }
    private var examples: [Example] = []
    private var idf: [String: Double] = [:]
    private static let word = try! NSRegularExpression(pattern: "[a-z][a-z0-9]{3,}")

    init(examples raw: [(path: String, text: String)], allTexts: [String], fallback: String) {
        guard !raw.isEmpty else { return }
        var df: [String: Int] = [:]
        for t in allTexts { for w in Learner.words(t) { df[w, default: 0] += 1 } }
        let n = Double(max(allTexts.count, 1))
        // Words in more than 15% of all screenshots (menu bars, UI chrome) carry no signal.
        idf = df.filter { Double($0.value) / n <= 0.15 }.mapValues { log(n / Double($0)) }
        for (path, text) in raw {
            let folder = (path as NSString).deletingLastPathComponent
            guard !folder.isEmpty, folder != fallback else { continue }
            let v = vector(text)
            if !v.isEmpty { examples.append(Example(folder: folder, name: (path as NSString).lastPathComponent, vector: v)) }
        }
    }

    private static func words(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        return Set(word.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)).compactMap { Range($0.range, in: lower).map { String(lower[$0]) } })
    }

    private func vector(_ text: String) -> [String: Double] {
        var v: [String: Double] = [:]
        for w in Learner.words(text) { if let weight = idf[w] { v[w] = weight } }
        let norm = sqrt(v.values.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.mapValues { $0 / norm } : [:]
    }

    /// The closest hand-filed screenshot, if it is similar enough to trust.
    func nearest(_ text: String) -> (folder: String, score: Int, example: String)? {
        guard !examples.isEmpty else { return nil }
        let q = vector(text)
        guard q.count >= 4 else { return nil }
        var best: (Example, Double)?
        for e in examples {
            var dot = 0.0
            for (w, x) in q { if let y = e.vector[w] { dot += x * y } }
            if dot > (best?.1 ?? 0) { best = (e, dot) }
        }
        guard let (e, sim) = best, sim >= 0.42 else { return nil }
        // 0.42 similarity scores about like a solid rule match; near-identical screenshots win outright.
        return (e.folder, Int((sim * 20).rounded()), e.name)
    }
}
