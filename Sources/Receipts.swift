import Foundation

struct Expense: Identifiable, Hashable {
    let id: String          // screenshot path
    let date: Date
    let merchant: String
    let category: String
    let amount: Double?
    let currency: String    // symbol as printed on the receipt: $, €, £, ₹

    var formattedAmount: String {
        guard let amount else { return "Not found" }
        return currency + amount.formatted(.number.precision(.fractionLength(2)))
    }
}

enum ReceiptParser {
    private static let money = try! NSRegularExpression(pattern: "([$€£₹])\\s?(\\d[\\d,]*\\.\\d{2})")
    private static let dates = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static func amounts(_ line: String) -> [(value: Double, currency: String)] {
        money.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { m in
            guard let cr = Range(m.range(at: 1), in: line), let vr = Range(m.range(at: 2), in: line),
                  let v = Double(line[vr].replacingOccurrences(of: ",", with: "")) else { return nil }
            return (v, String(line[cr]))
        }
    }

    /// The total: the amount on a "total" line (not subtotal), else the largest amount on the receipt.
    static func amount(_ text: String) -> (value: Double, currency: String)? {
        let lines = text.split(separator: "\n").map(String.init)
        for (i, line) in lines.enumerated() {
            let l = line.lowercased()
            guard l.contains("total") || l.contains("amount paid") || l.contains("amount charged"), !l.contains("subtotal") else { continue }
            if let a = amounts(line).last, a.value > 0 { return a }
            if i + 1 < lines.count, let a = amounts(lines[i + 1]).first, a.value > 0 { return a }
        }
        return amounts(text).filter { $0.value > 0 }.max { $0.value < $1.value }
    }

    /// The first date printed on the receipt with an explicit day, month and year, else when the
    /// screenshot was taken. Relative words ("today", "tomorrow") and dates after the screenshot are ignored.
    static func date(_ text: String, fallback taken: Date) -> Date {
        let range = NSRange(text.startIndex..., in: text)
        let earliest = Calendar.current.date(byAdding: .year, value: -15, to: taken) ?? .distantPast
        for m in dates?.matches(in: text, range: range) ?? [] {
            guard let d = m.date, d > earliest, d <= taken.addingTimeInterval(86_400),
                  let r = Range(m.range, in: text), explicit.firstMatch(in: String(text[r]), range: NSRange(location: 0, length: m.range.length)) != nil
            else { continue }
            return d
        }
        return taken
    }

    private static let explicit = try! NSRegularExpression(pattern: "\\d{1,4}[/.-]\\d{1,2}[/.-]\\d{2,4}|[A-Za-z]{3,9}\\.? \\d{1,2},? \\d{4}|\\d{1,2} [A-Za-z]{3,9},? \\d{4}")

    static func expense(path: String, text: String, taken: Date) -> Expense {
        let parts = path.split(separator: "/").map(String.init).dropLast()
        let category = parts.count > 1 ? parts[1] : "Other"
        let merchant = parts.count > 2 ? parts[2] : "—"
        let a = amount(text)
        return Expense(id: path, date: date(text, fallback: taken), merchant: merchant, category: category,
                       amount: a?.value, currency: a?.currency ?? "$")
    }
}
