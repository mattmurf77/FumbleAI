import Foundation
import HomeCore

/// Pure receipt parser (LLD §15 step 3). Every value is a *suggestion* the user confirms ("From receipt – check").
///
/// - Amounts: `(?<!\d)\$?\s?(\d{1,3}(,\d{3})*|\d+)\.\d{2}(?!\d)`.
/// - Total: largest amount on lines matching `(?i)\b(grand\s+)?total\b|amount\s+due|balance\s+due` (an amount printed
///   as a separate OCR line on the same row, or on the next line, also counts); else the largest amount in the
///   bottom 40 % of the page.
/// - Date: the first date that is ≤ today and within the last 5 years. `NSDataDetector` is unavailable off Apple
///   platforms, so common receipt formats are matched explicitly (numeric M/D/Y, Y-M-D, D.M.Y when unambiguous,
///   "Sep 18, 2026", "18 Sep 2026").
/// - Vendor: the first line in the top 20 % with 3–40 characters, ≥ 50 % letters and no amount.
public struct ReceiptParser: ReceiptParsing {
    public var currency: String
    public init(currency: String = "USD") { self.currency = currency }

    static let amountPattern = #"(?<!\d)\$?\s?(\d{1,3}(,\d{3})*|\d+)\.\d{2}(?!\d)"#
    static let totalPattern = #"(?i)\b(grand\s+)?total\b|amount\s+due|balance\s+due"#
    static let amountRegex = try! NSRegularExpression(pattern: amountPattern)
    static let totalRegex = try! NSRegularExpression(pattern: totalPattern)
    /// Lines that mention "total" but are not the amount paid.
    static let notTotalRegex = try! NSRegularExpression(pattern: #"(?i)\b(sub\s*-?\s*total|total\s+(savings|saved|discount|items?|qty|quantity|tax))\b"#)

    public func parse(lines raw: [OCRLine], today: LocalDate) -> ReceiptGuess {
        let lines = raw.enumerated().sorted { ($0.element.y, $0.offset) < ($1.element.y, $1.offset) }.map(\.element)
        let fullText = lines.map(\.text).joined(separator: "\n")
        return ReceiptGuess(total: total(lines).map { Money(cents: $0, currency: currency) },
                            date: date(lines, today: today), vendor: vendor(lines), fullText: fullText)
    }

    // MARK: Amounts

    /// Amounts (cents) found in a string, in order.
    public static func amounts(in text: String) -> [Int64] {
        let ns = text as NSString
        return amountRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let s = ns.substring(with: m.range)
            let digits = s.filter { $0.isNumber || $0 == "." }
            guard let dec = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            return NSDecimalNumber(decimal: dec * 100).int64Value
        }
    }

    static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    func total(_ lines: [OCRLine]) -> Int64? {
        var candidates: [Int64] = []
        for (i, l) in lines.enumerated() where Self.matches(Self.totalRegex, l.text) && !Self.matches(Self.notTotalRegex, l.text) {
            var found = Self.amounts(in: l.text)
            if found.isEmpty {
                // Right-column amount recognized as its own line: same row (|Δy| ≤ 1.5 %), else the next line.
                found = lines.filter { $0 != l && abs($0.y - l.y) <= 0.015 }.flatMap { Self.amounts(in: $0.text) }
                if found.isEmpty, i + 1 < lines.count { found = Self.amounts(in: lines[i + 1].text) }
            }
            candidates += found
        }
        if let m = candidates.max() { return m }
        return lines.filter { $0.y >= 0.6 }.flatMap { Self.amounts(in: $0.text) }.max()
    }

    // MARK: Vendor

    func vendor(_ lines: [OCRLine]) -> String? {
        for l in lines where l.y <= 0.2 {
            let t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (3...40).contains(t.count), Self.amounts(in: t).isEmpty else { continue }
            let letters = t.filter(\.isLetter).count
            guard Double(letters) >= 0.5 * Double(t.count) else { continue }
            return t
        }
        return nil
    }

    // MARK: Dates

    static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
    ]
    static let numericRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,4})[/\-.](\d{1,2})[/\-.](\d{2,4})(?!\d)"#)
    static let monthFirstRegex = try! NSRegularExpression(pattern: #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#)
    static let dayFirstRegex = try! NSRegularExpression(pattern: #"(?i)\b(\d{1,2})(?:st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?,?\s+(\d{4})\b"#)

    /// All date candidates in a line, in textual order.
    public static func dates(in text: String) -> [LocalDate] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var found: [(Int, LocalDate)] = []
        func g(_ m: NSTextCheckingResult, _ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        for m in numericRegex.matches(in: text, range: range) {
            let a = g(m, 1), b = Int(g(m, 2))!, c = g(m, 3)
            var candidates: [LocalDate?] = []
            if a.count == 4 {
                candidates = [make(Int(a)!, b, Int(c)!)]                       // Y-M-D
            } else if c.count == 4 || c.count == 2 {
                let y = c.count == 2 ? 2000 + Int(c)! : Int(c)!
                let first = Int(a)!
                candidates = [make(y, first, b)]                              // M/D/Y (US receipts)
                if first > 12 { candidates = [make(y, b, first)] }            // D/M/Y when unambiguous
            }
            if let d = candidates.compactMap({ $0 }).first { found.append((m.range.location, d)) }
        }
        for m in monthFirstRegex.matches(in: text, range: range) {
            if let mo = months[g(m, 1).lowercased()], let d = make(Int(g(m, 3))!, mo, Int(g(m, 2))!) { found.append((m.range.location, d)) }
        }
        for m in dayFirstRegex.matches(in: text, range: range) {
            if let mo = months[g(m, 2).lowercased()], let d = make(Int(g(m, 3))!, mo, Int(g(m, 1))!) { found.append((m.range.location, d)) }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func make(_ y: Int, _ m: Int, _ d: Int) -> LocalDate? {
        guard (1900...2200).contains(y), (1...12).contains(m), d >= 1, d <= LocalDate.daysInMonth(year: y, month: m) else { return nil }
        return LocalDate(y, m, d)
    }

    func date(_ lines: [OCRLine], today: LocalDate) -> LocalDate? {
        let earliest = today.adding(months: -60)
        for l in lines {
            for d in Self.dates(in: l.text) where d <= today && d >= earliest { return d }
        }
        return nil
    }
}
