import Foundation

/// Turns dictated or pasted text into separate to-do titles: voice capture, "Paste a list", and lists shared from
/// Notes or Messages.
///
/// Several lines (a Notes checklist, a pasted list) → one item per line, with bullets, checkboxes and numbering
/// removed and heading lines ("Weekend jobs:") dropped. A single line (dictation) → split at commas, semicolons and
/// spoken separators ("and then", "next item", "new item"), with the Oxford "and" of "a, b and c" split too.
public enum ListCapture {
    public static let maxTitleLength = 200

    public static func items(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var raw: [String]
        if lines.count > 1 {
            raw = lines.filter { !isHeading($0) }.map(stripMarker)
        } else if let line = lines.first {
            raw = splitSpoken(stripMarker(line))
        } else {
            raw = []
        }

        var seen = Set<String>()
        var out: [String] = []
        for item in raw.map(clean) where !item.isEmpty {
            let key = item.lowercased()
            if seen.insert(key).inserted { out.append(item) }
        }
        return out
    }

    // MARK: Pieces

    /// "- ", "• ", "* ", "1. ", "2) ", "[ ] ", "- [x] ", "☐ ", "✅ " at the start of a line.
    private static let marker = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:[-*+•●◦▪–—·]|\d{1,3}[.)])\s*)?(?:\[[ xX✓]?\]|[☐☑✅✔✓□■])?\s*"#)

    /// Spoken or typed separators inside one line.
    private static let separator = try! NSRegularExpression(
        pattern: #"\s*(?:[,;]|\band then\b|\bnext item\b|\bnew item\b|\bnew line\b)\s*"#,
        options: [.caseInsensitive])

    static func stripMarker(_ line: String) -> String {
        let range = NSRange(line.startIndex..., in: line)
        return marker.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    /// A list title such as "Weekend jobs:" (ends with a colon).
    static func isHeading(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasSuffix(":")
    }

    static func splitSpoken(_ line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        let marked = separator.stringByReplacingMatches(in: line, range: range, withTemplate: "\u{1F}")
        var parts = marked.split(separator: "\u{1F}", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return parts }
        // "a, b and c" / "a, b, and c": the last part holds two items.
        if var last = parts.popLast() {
            if last.lowercased().hasPrefix("and ") {
                last = String(last.dropFirst(4))
                parts.append(last)
            } else if let r = last.range(of: " and ", options: [.caseInsensitive, .backwards]) {
                parts.append(String(last[..<r.lowerBound]))
                parts.append(String(last[r.upperBound...]))
            } else {
                parts.append(last)
            }
        }
        return parts
    }

    /// Trims spaces and trailing punctuation, collapses runs of spaces, capitalizes the first letter.
    static func clean(_ item: String) -> String {
        var s = item.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, ".,;:!".contains(last) { s.removeLast() }
        s = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if s.count > maxTitleLength { s = String(s.prefix(maxTitleLength)) }
        guard let first = s.first else { return "" }
        return first.uppercased() + s.dropFirst()
    }
}
