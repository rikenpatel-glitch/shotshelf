// shotshelf: command-line companion to Shotshelf.app, built from the same sources.
//   shotshelf explain FILE          why a screenshot goes where it does
//   shotshelf sort DIR [--dry-run]  sort every image under DIR (for old screenshot folders)
//   shotshelf stats                 where every indexed screenshot would go with the current rules
//   shotshelf expenses              date, merchant and amount read from every screenshot in Receipts (CSV)
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let config = AppConfig()
let sorter = Sorter(config: config)

func usage() -> Never {
    print("usage: shotshelf explain FILE | sort DIR [--dry-run] | stats | expenses")
    exit(1)
}

switch args.first {
case "explain":
    guard args.count > 1 else { usage() }
    let url = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    let a = sorter.analyze([url])[url] ?? Analysis(text: "")
    let c = Classifier(config: config, index: sorter.index)
    print("Text: " + a.text.split(separator: "\n").joined(separator: " | ").prefix(300))
    if let labels = a.labels, !labels.isEmpty { print("Image: \(labels)") }
    if let app = Classifier.appName(a.text) { print("App: \(app)") }
    print("")
    for r in c.ranked(a.text, labels: a.labels).prefix(5) {
        print(String(format: "%4d  %@  (%@)", r.score, r.folder.padding(toLength: 42, withPad: " ", startingAt: 0), r.hits.prefix(8).joined(separator: ", ")))
    }
    print("\n-> \(c.classify(a.text, labels: a.labels))")
case "sort":
    guard args.count > 1 else { usage() }
    let base = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    let dry = args.contains("--dry-run")
    var files: [URL] = []
    if let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
        for case let u as URL in e where ShotFile.isImage(u) { files.append(u) }
    }
    print("\(files.count) image(s)")
    var counts: [String: Int] = [:]
    if dry {
        let c = Classifier(config: config, index: sorter.index)
        for (_, a) in sorter.analyze(files) { counts[c.classify(a.text, labels: a.labels), default: 0] += 1 }
    } else {
        for r in sorter.sort(files) { counts[r.folder, default: 0] += 1 }
    }
    for (f, n) in counts.sorted(by: { $0.value > $1.value }) { print(String(format: "%5d  %@", n, f)) }
    let waiting = files.filter(ShotFile.isInCloudOnly).count
    if waiting > 0 { print("\n\(waiting) still in iCloud, skipped (download requested; run again once they arrive)") }
case "stats":
    let c = Classifier(config: config, index: sorter.index)
    var counts: [String: Int] = [:]
    var moves = 0
    for e in sorter.index.entries() {
        let folder = c.classify(e.text ?? "", labels: sorter.index.labels(forPath: e.path))
        counts[folder.components(separatedBy: "/").prefix(2).joined(separator: "/"), default: 0] += 1
        if folder != (e.path as NSString).deletingLastPathComponent { moves += 1 }
    }
    for (f, n) in counts.sorted(by: { $0.value > $1.value }) { print(String(format: "%5d  %@", n, f)) }
    print("\n\(moves) would land somewhere other than where they are now")
case "expenses":
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withFullDate]
    print("Date,Merchant,Category,Amount,Currency,Screenshot")
    func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    var seen = Set<String>()
    for e in sorter.index.entries() where e.path.hasPrefix("Receipts/") && (e.hash.map { seen.insert($0).inserted } ?? true) {
        let x = ReceiptParser.expense(path: e.path, text: e.text ?? "", taken: Date(timeIntervalSince1970: e.ts))
        print([iso.string(from: x.date), q(x.merchant), q(x.category), x.amount.map { String(format: "%.2f", $0) } ?? "", x.currency, q(e.path)].joined(separator: ","))
    }
default:
    usage()
}
