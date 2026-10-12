import Foundation
import CryptoKit

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var configFile: URL {
        if let custom = ProcessInfo.processInfo.environment["SHOTSHELF_CONFIG"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".config/shotshelf/config.json")
    }

    static let dataDir = home.appendingPathComponent("Library/Application Support/Shotshelf")

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    /// Where macOS currently saves screenshots (System Settings or `defaults write com.apple.screencapture location`).
    static var systemScreenshotFolder: URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            return expand(loc)
        }
        return home.appendingPathComponent("Desktop")
    }
}

/// Settings from ~/.config/shotshelf/config.json layered over the bundled default rules.
final class AppConfig {
    let root: URL
    let projectsDirs: [URL]
    let projectIgnore: Set<String>
    let projectGeneric: Set<String>
    let fallback: String
    let gates: [String: [String: Any]]
    let rules: [[String: Any]]
    let raw: [String: Any]

    static var exists: Bool { FileManager.default.fileExists(atPath: Paths.configFile.path) }

    init() {
        let defaults = AppConfig.defaultRules()
        var user: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.configFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            user = obj
        }
        raw = user
        root = Paths.expand(user["screenshots_dir"] as? String ?? Paths.systemScreenshotFolder.path)
        projectsDirs = (user["projects_dirs"] as? [String] ?? []).map(Paths.expand)
        projectIgnore = Set((user["project_ignore"] as? [String] ?? []).map { $0.lowercased() })
        projectGeneric = Set((user["project_generic_names"] as? [String] ?? []).map { $0.lowercased() })
        fallback = user["fallback"] as? String ?? defaults["fallback"] as? String ?? "General"
        var g = defaults["gates"] as? [String: [String: Any]] ?? [:]
        for (k, v) in user["gates"] as? [String: [String: Any]] ?? [:] { g[k] = v }
        gates = g
        let base = user["rules"] as? [[String: Any]] ?? defaults["rules"] as? [[String: Any]] ?? []
        rules = (user["extra_rules"] as? [[String: Any]] ?? []) + base
    }

    static func defaultRules() -> [String: Any] {
        let candidates = [
            Bundle.main.url(forResource: "rules.default", withExtension: "json"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("rules.default.json"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        return ["fallback": "General", "gates": [:], "rules": []]
    }

    /// Update keys in the user's config file, keeping everything else as written.
    static func write(_ changes: [String: Any]) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: Paths.configFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        for (k, v) in changes { obj[k] = v }
        try? FileManager.default.createDirectory(at: Paths.configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.configFile)
        }
    }

    /// Index and lock files are keyed by the screenshots folder, so two folders never share state.
    var dataKey: String {
        let digest = Insecure.SHA1.hash(data: Data(root.path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    /// Display a path with ~ for the home folder.
    static func tilde(_ url: URL) -> String {
        let home = Paths.home.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
