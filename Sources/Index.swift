import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Text-recognition cache and search index. One SQLite file per screenshots folder.
final class IndexDB {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "shotshelf.index")

    init(file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        sqlite3_busy_timeout(db, 5000)
        exec("""
            CREATE TABLE IF NOT EXISTS shots (
                path TEXT PRIMARY KEY, hash TEXT, text TEXT, folder TEXT, how TEXT, ts REAL)
            """)
        exec("CREATE INDEX IF NOT EXISTS shots_hash ON shots(hash)")
        // Added after 1.0: image labels for text-less screenshots, a look-alike fingerprint, last opened time.
        for column in ["labels TEXT", "phash TEXT", "opened REAL"] { exec("ALTER TABLE shots ADD COLUMN \(column)") }
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        queue.sync { _ = sqlite3_exec(db, sql, nil, nil, nil) }
    }

    private enum Arg { case text(String?), real(Double?) }

    private func run(_ sql: String, _ args: [Arg] = [], row: ((OpaquePointer) -> Void)? = nil) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            defer { sqlite3_finalize(stmt) }
            for (i, arg) in args.enumerated() {
                let idx = Int32(i + 1)
                switch arg {
                case .text(let s?): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
                case .text(nil): sqlite3_bind_null(stmt, idx)
                case .real(let d?): sqlite3_bind_double(stmt, idx, d)
                case .real(nil): sqlite3_bind_null(stmt, idx)
                }
            }
            while sqlite3_step(stmt) == SQLITE_ROW { row?(stmt) }
        }
    }

    private static func col(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    func text(forHash hash: String) -> String? {
        var out: String?
        run("SELECT text FROM shots WHERE hash=? AND text IS NOT NULL LIMIT 1", [.text(hash)]) { out = IndexDB.col($0, 0) }
        return out
    }

    func text(forPath path: String) -> String? {
        var out: String?
        run("SELECT text FROM shots WHERE path=?", [.text(path)]) { out = IndexDB.col($0, 0) }
        return out
    }

    func record(path: String, hash: String?, text: String?, how: String, ts: Double) {
        let folder = (path as NSString).deletingLastPathComponent
        run("INSERT OR REPLACE INTO shots(path, hash, text, folder, how, ts) VALUES (?,?,?,?,?,?)",
            [.text(path), .text(hash), .text(text), .text(folder), .text(how), .real(ts)])
    }

    func row(path: String) -> (hash: String?, text: String?, ts: Double)? {
        var out: (String?, String?, Double)?
        run("SELECT hash, text, ts FROM shots WHERE path=?", [.text(path)]) {
            out = (IndexDB.col($0, 0), IndexDB.col($0, 1), sqlite3_column_double($0, 2))
        }
        return out.map { (hash: $0.0, text: $0.1, ts: $0.2) }
    }

    func rename(from old: String, to new: String, how: String) {
        let folder = (new as NSString).deletingLastPathComponent
        // A file that stays where it is keeps its row; only a different destination clears a stale one.
        if old != new { run("DELETE FROM shots WHERE path=?", [.text(new)]) }
        run("UPDATE shots SET path=?, folder=?, how=? WHERE path=?", [.text(new), .text(folder), .text(how), .text(old)])
    }

    func delete(path: String) {
        run("DELETE FROM shots WHERE path=?", [.text(path)])
    }

    func setText(path: String, text: String) {
        run("UPDATE shots SET text=? WHERE path=?", [.text(text), .text(path)])
    }

    func analysis(forHash hash: String) -> (labels: String?, phash: String?)? {
        var out: (String?, String?)?
        run("SELECT labels, phash FROM shots WHERE hash=? AND phash IS NOT NULL LIMIT 1", [.text(hash)]) {
            out = (IndexDB.col($0, 0), IndexDB.col($0, 1))
        }
        return out.map { (labels: $0.0, phash: $0.1) }
    }

    func setAnalysis(path: String, labels: String?, phash: String?) {
        run("UPDATE shots SET labels=?, phash=? WHERE path=?", [.text(labels), .text(phash), .text(path)])
    }

    func labels(forPath path: String) -> String? {
        var out: String?
        run("SELECT labels FROM shots WHERE path=?", [.text(path)]) { out = IndexDB.col($0, 0) }
        return out
    }

    func markOpened(path: String) {
        run("UPDATE shots SET opened=? WHERE path=?", [.real(Date().timeIntervalSince1970), .text(path)])
    }

    func pathsMissingAnalysis() -> [String] {
        var out: [String] = []
        run("SELECT path FROM shots WHERE phash IS NULL") { if let p = IndexDB.col($0, 0) { out.append(p) } }
        return out
    }

    /// Screenshots you filed yourself: the examples the sorter learns from.
    func manualExamples() -> [(path: String, text: String)] {
        var out: [(String, String)] = []
        run("SELECT path, text FROM shots WHERE how='manual' AND text IS NOT NULL AND length(text) > 20") { stmt in
            if let p = IndexDB.col(stmt, 0), let t = IndexDB.col(stmt, 1) { out.append((p, t)) }
        }
        return out.map { (path: $0.0, text: $0.1) }
    }

    struct Entry { let path: String; let hash: String?; let phash: String?; let text: String?; let ts: Double; let opened: Double? }

    func entries() -> [Entry] {
        var out: [Entry] = []
        run("SELECT path, hash, phash, text, ts, opened FROM shots") { stmt in
            guard let p = IndexDB.col(stmt, 0) else { return }
            let opened = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
            out.append(Entry(path: p, hash: IndexDB.col(stmt, 1), phash: IndexDB.col(stmt, 2), text: IndexDB.col(stmt, 3),
                             ts: sqlite3_column_double(stmt, 4), opened: opened))
        }
        return out
    }

    func allTexts() -> [String] {
        var out: [String] = []
        run("SELECT text FROM shots WHERE text IS NOT NULL AND text != ''") { if let t = IndexDB.col($0, 0) { out.append(t) } }
        return out
    }

    func allHashes() -> [String: String] {
        var out: [String: String] = [:]
        run("SELECT path, hash FROM shots") { stmt in
            if let p = IndexDB.col(stmt, 0) { out[p] = IndexDB.col(stmt, 1) ?? "" }
        }
        return out
    }

    func pathsMissingText() -> [String] {
        var out: [String] = []
        run("SELECT path FROM shots WHERE text IS NULL") { if let p = IndexDB.col($0, 0) { out.append(p) } }
        return out
    }

    /// Paths whose recognized text or file name contains every word of the query.
    func search(_ query: String) -> [String] {
        let words = query.split(separator: " ").map { "%" + $0.replacingOccurrences(of: "%", with: "") + "%" }
        guard !words.isEmpty else { return [] }
        let clause = Array(repeating: "(text LIKE ? OR path LIKE ?)", count: words.count).joined(separator: " AND ")
        var args: [Arg] = []
        for w in words { args += [.text(w), .text(w)] }
        var out: [String] = []
        run("SELECT path FROM shots WHERE \(clause) ORDER BY ts DESC LIMIT 3000", args) { if let p = IndexDB.col($0, 0) { out.append(p) } }
        return out
    }
}
