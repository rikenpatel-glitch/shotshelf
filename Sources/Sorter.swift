import Foundation
import Vision
import ImageIO
import CryptoKit

/// Everything Shotshelf reads from an image, all on this Mac with Apple's Vision framework.
struct Analysis {
    var text: String
    var labels: String?     // "people:0.96,adult:0.94", only for screenshots with little text
    var phash: String?      // 64-bit difference hash, for spotting look-alikes
    var hash: String?       // SHA-1 of the file, for exact duplicates and the text cache

    /// Labels with their confidence, from the stored "name:0.93,other:0.71" form.
    static func parse(_ labels: String?) -> [String: Double] {
        var out: [String: Double] = [:]
        for part in (labels ?? "").split(separator: ",") {
            let kv = part.split(separator: ":")
            if kv.count == 2, let c = Double(kv[1]) { out[String(kv[0])] = c }
        }
        return out
    }
}

enum Vision2 {
    static let labelTextLimit = 80

    static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func text(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func labels(_ image: CGImage) -> String {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { $0.confidence >= 0.3 }.prefix(12)
            .map { "\($0.identifier):\(String(format: "%.2f", $0.confidence))" }.joined(separator: ",")
    }

    /// Difference hash: shrink to 9x8 grayscale and compare neighbouring pixels.
    static func dhash(_ image: CGImage) -> String? {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bits: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                bits <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { bits |= 1 }
            }
        }
        return String(format: "%016llx", bits)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        guard let x = UInt64(a, radix: 16), let y = UInt64(b, radix: 16) else { return 64 }
        return (x ^ y).nonzeroBitCount
    }

    static func analyze(_ url: URL, text known: String? = nil) -> Analysis {
        let hash = ShotFile.hash(url)
        guard let image = image(url) else { return Analysis(text: known ?? "", hash: hash) }
        let text = known ?? self.text(image)
        let labels = text.count < labelTextLimit ? self.labels(image) : nil
        return Analysis(text: text, labels: labels, phash: dhash(image), hash: hash)
    }
}

enum ShotFile {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"]
    private static let nameDate = try! NSRegularExpression(
        pattern: "^(?:Screenshot|Screen Shot|CleanShot)\\s+(\\d{4})-(\\d{2})-(\\d{2})\\s+at\\s+(\\d{1,2})[.:](\\d{2})[.:](\\d{2})\\s*([AP]M)?",
        options: .caseInsensitive)

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix(".")
    }

    /// When the screenshot was taken: from the macOS file name if present, else the file's creation date.
    static func date(_ url: URL) -> Date {
        let name = url.lastPathComponent
        if let m = nameDate.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) {
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: name).map { String(name[$0]) } }
            var c = DateComponents()
            c.year = Int(g(1) ?? ""); c.month = Int(g(2) ?? ""); c.day = Int(g(3) ?? "")
            var hour = Int(g(4) ?? "") ?? 0
            if let ampm = g(7)?.uppercased() { hour = hour % 12 + (ampm == "PM" ? 12 : 0) }
            c.hour = hour; c.minute = Int(g(5) ?? ""); c.second = Int(g(6) ?? "")
            if let d = Calendar.current.date(from: c) { return d }
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    static func hash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func uniqueDestination(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var i = 2
        while fm.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(stem) (\(i))" + (ext.isEmpty ? "" : ".\(ext)"))
            i += 1
        }
        return dest
    }
}

struct SortResult: Identifiable {
    let id = UUID()
    let name: String
    let folder: String
    let path: String
    let date = Date()
}

/// Moves screenshots into folders and keeps the index in sync. All work runs on `queue`.
final class Sorter {
    let config: AppConfig
    let index: IndexDB
    /// New screenshots are sorted here, so they never wait behind background indexing.
    let queue = DispatchQueue(label: "shotshelf.sorter", qos: .userInitiated)
    /// Catching up on old screenshots (text, labels, fingerprints) runs here.
    let backgroundQueue = DispatchQueue(label: "shotshelf.indexer", qos: .utility)

    init(config: AppConfig) {
        self.config = config
        index = IndexDB(file: Paths.dataDir.appendingPathComponent(config.dataKey + ".db"))
    }

    var root: URL { config.root }

    func relative(_ url: URL) -> String {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : p
    }

    /// Screenshots sitting directly in the screenshots folder, waiting to be sorted.
    func inboxFiles(settled: Bool = true) -> [URL] {
        let kids = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: .skipsHiddenFiles)) ?? []
        return kids.filter { url in
            guard ShotFile.isImage(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            guard settled else { return true }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Date().timeIntervalSince(modified) > 1
        }
    }

    /// Analysis for each file, reusing cached results for identical files.
    func analyze(_ files: [URL]) -> [URL: Analysis] {
        // Without this, App Nap throttles the work whenever the window isn't in front.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Reading screenshots")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var out: [URL: Analysis] = [:]
        let lock = NSLock()
        // Each call gets its own queue, so a quick sort never waits on another call's batch.
        let ocrQueue = OperationQueue()
        ocrQueue.maxConcurrentOperationCount = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 3))
        ocrQueue.qualityOfService = .userInitiated
        for f in files {
            ocrQueue.addOperation { [index] in
                let hash = ShotFile.hash(f)
                var result: Analysis
                if let hash, let cached = index.text(forHash: hash) {
                    if let extra = index.analysis(forHash: hash) {
                        result = Analysis(text: cached, labels: extra.labels, phash: extra.phash, hash: hash)
                    } else {
                        result = Vision2.analyze(f, text: cached)
                    }
                } else {
                    result = Vision2.analyze(f)
                }
                lock.lock(); out[f] = result; lock.unlock()
            }
        }
        ocrQueue.waitUntilAllOperationsAreFinished()
        return out
    }

    @discardableResult
    func move(_ src: URL, to folder: String, how: String, analysis: Analysis? = nil) throws -> URL {
        let text = analysis?.text, hash = analysis?.hash
        let target = folder.isEmpty ? root : root.appendingPathComponent(folder)
        guard target.standardizedFileURL.path.hasPrefix(root.path) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let old = relative(src)
        var dest = src
        if src.deletingLastPathComponent().standardizedFileURL.path != target.standardizedFileURL.path {
            dest = ShotFile.uniqueDestination(in: target, name: src.lastPathComponent)
            try FileManager.default.moveItem(at: src, to: dest)
        }
        let new = relative(dest)
        if let existing = index.row(path: old) {
            index.rename(from: old, to: new, how: how)
            if existing.text == nil, let text { index.setText(path: new, text: text) }
        } else {
            index.record(path: new, hash: hash ?? ShotFile.hash(dest), text: text, how: how, ts: ShotFile.date(dest).timeIntervalSince1970)
        }
        if let analysis, analysis.phash != nil { index.setAnalysis(path: new, labels: analysis.labels, phash: analysis.phash) }
        return dest
    }

    /// Sort the given files into folders. Must run on `queue`.
    func sort(_ files: [URL]) -> [SortResult] {
        guard !files.isEmpty else { return [] }
        let classifier = Classifier(config: config, index: index)
        let results = analyze(files)
        var sorted: [SortResult] = []
        for f in files {
            let a = results[f] ?? Analysis(text: "")
            let folder = classifier.classify(a.text, labels: a.labels)
            if let dest = try? move(f, to: folder, how: "auto", analysis: a) {
                sorted.append(SortResult(name: dest.deletingPathExtension().lastPathComponent, folder: folder, path: relative(dest)))
            }
        }
        return sorted
    }

    func sortInbox() -> [SortResult] { sort(inboxFiles()) }

    /// Bring the index in line with the disk (files moved in Finder, new files), then read any missing text.
    func reconcile(progress: (Int, Int) -> Void) {
        let fm = FileManager.default
        var onDisk: [String: URL] = [:]
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in e where ShotFile.isImage(url) { onDisk[relative(url)] = url }
        }
        let known = index.allHashes()
        var gone: [String: String] = [:]
        for (path, hash) in known where onDisk[path] == nil { gone[hash] = path }
        for (rel, url) in onDisk where known[rel] == nil {
            let h = ShotFile.hash(url)
            if let h, let old = gone.removeValue(forKey: h) {
                index.rename(from: old, to: rel, how: "found")
            } else {
                index.record(path: rel, hash: h, text: nil, how: "found", ts: ShotFile.date(url).timeIntervalSince1970)
            }
        }
        for path in gone.values { index.delete(path: path) }

        // Read text, image labels and fingerprints for anything not analysed yet.
        let missing = Array(Set(index.pathsMissingText() + index.pathsMissingAnalysis()))
            .map { root.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        let batch = 24
        for start in stride(from: 0, to: missing.count, by: batch) {
            let part = Array(missing[start..<min(start + batch, missing.count)])
            for (url, a) in analyze(part) {
                let rel = relative(url)
                index.setText(path: rel, text: a.text)
                index.setAnalysis(path: rel, labels: a.labels, phash: a.phash)
            }
            progress(min(start + batch, missing.count), missing.count)
        }
    }
}
