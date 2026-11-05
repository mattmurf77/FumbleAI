import Foundation
import HomeCore

/// Extracts labeled facts only. Approval, inspection and payment dates remain separate from completed work.
struct DocumentFieldParser {
    struct Page {
        let number: Int
        let lines: [String]
    }

    static func candidates(in pages: [Page]) -> [DocumentCandidate] {
        var results: [DocumentCandidate] = []
        var seen = Set<String>()
        func add(_ field: DocumentField, _ value: String, line: String, page: Int) {
            guard results.count < 64, !value.isEmpty, !value.contains("\u{fffd}") else { return }
            let bounded = String(value.prefix(140))
            guard seen.insert(field.rawValue + "|" + bounded.lowercased()).inserted else { return }
            results.append(.init(field: field, value: bounded, excerpt: String(line.prefix(260)), page: page))
        }
        var category: String?
        for page in pages {
            // A packet can contain a permit and a later invoice. Totals belong to the document headed on this page.
            if let heading = page.lines.prefix(12).first(where: { detectCategory($0) != nil }),
               let type = detectCategory(heading) {
                category = type
                add(.category, type, line: heading, page: page.number)
                if heading.count <= 90, heading.range(of: #"[0-9]{3,}"#, options: .regularExpression) == nil {
                    add(.title, heading, line: heading, page: page.number)
                }
            }
            for (index, raw) in page.lines.enumerated() {
                var line = String(raw.prefix(400))
                if (line.hasSuffix(":") || line.hasSuffix("#")), index + 1 < page.lines.count {
                    let next = page.lines[index + 1]
                    if !next.contains(":") && next.count <= 140 { line += " " + next }
                }
                for rule in rules {
                    guard let capture = rule.match(line) else { continue }
                    switch rule.field {
                    case .referenceNumber:
                        if capture.range(of: #"^[A-Za-z0-9][A-Za-z0-9./-]{1,63}$"#, options: .regularExpression) != nil,
                           capture.contains(where: \.isNumber) { add(rule.field, capture, line: line, page: page.number) }
                    case .issuedDate, .inspectionDate, .finalDate, .completionDate, .warrantyEnd, .receiptDate, .invoiceDate:
                        if let date = unambiguousDate(capture) { add(rule.field, date, line: line, page: page.number) }
                    default: add(rule.field, capture, line: line, page: page.number)
                    }
                }
                if let category, let rule = totals[category], let total = rule.match(line),
                   total.firstMatch(of: amountRegex) != nil {
                    add(rule.field, total, line: line, page: page.number)
                }
                if category == "receipt" || category == "invoice",
                   let label = dateRule.match(line), let date = unambiguousDate(label) {
                    add(category == "receipt" ? .receiptDate : .invoiceDate, date, line: line, page: page.number)
                }
            }
        }
        return results
    }

    private static func detectCategory(_ line: String) -> String? {
        for (category, rule) in headings where rule.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            return category
        }
        return nil
    }

    private struct Rule {
        let field: DocumentField
        let expression: NSRegularExpression
        init(_ field: DocumentField, _ labels: String) {
            self.field = field
            expression = try! NSRegularExpression(pattern: #"^\s*(?:"# + labels + #")\s*(?:[:#=]\s*|\s+)(\S.*?)\s*$"#, options: .caseInsensitive)
        }
        func match(_ line: String) -> String? {
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[range]).trimmingCharacters(in: .whitespaces)
        }
    }

    private static let headings: [(String, NSRegularExpression)] = [
        ("inspection", #"^(?:(?:final|building|electrical|plumbing|mechanical|home)\s+){0,2}inspection(?:\s+(?:report|record|certificate|results))?\s*$"#),
        ("permit", #"^(?:(?:building|construction|electrical|plumbing|mechanical|residential|roofing|work)\s+){0,3}permit(?:\s+(?:record|certificate|application|number|no\.?|#)\b|\s*$)"#),
        ("estimate", #"^(?:(?:contractor|construction|project|work|price|job|cost|roofing|service)\s+)?(?:estimate|quote|quotation|bid)(?:\s*(?:#|no\.|number|:)|\s*$)|^(?:price|project|contractor|construction) proposal\s*$"#),
        ("warranty", #"^(?:[\p{L} -]{0,55}\s+)?warranty(?:\s+(?:certificate|information|terms|registration|coverage))?\s*$"#),
        ("receipt", #"^(?:(?:sales|payment|purchase|customer|transaction)\s+)?receipt(?:\s*(?:#|no\.|number|:)|\s*$)"#),
        ("invoice", #"^(?:(?:tax|service|sales|commercial)\s+)?invoice(?:\s*(?:#|no\.|number|:)|\s*$)"#),
        ("insurance", #"^(?:(?:homeowners?|property)\s+)?insurance(?:\s+(?:policy|declarations|certificate))?\s*$"#),
        ("manual", #"^(?:(?:owner['’]?s|user|installation|operating|service)\s+)?manual\s*$"#)
    ].map { ($0, try! NSRegularExpression(pattern: $1, options: .caseInsensitive)) }

    private static let rules: [Rule] = [
        Rule(.title, #"document title|project title|job title"#),
        Rule(.issuer, #"issued by|issuing (?:authority|agency|department)|issuer|manufacturer|seller|vendor"#),
        Rule(.contractor, #"contractor(?: name)?|licensed contractor|installed by|performed by"#),
        Rule(.referenceNumber, #"(?:(?:permit|inspection|invoice|receipt|policy|reference|warranty)\s*(?:number|no\.?|id|#))|(?:permit|invoice|receipt|policy)\s*(?=#)"#),
        Rule(.issuedDate, #"date issued|issued on|issued date|issue date|permit issued"#),
        Rule(.inspectionDate, #"inspection date|date inspected|inspected on|final inspection date"#),
        Rule(.finalDate, #"final approval date|date finaled|finaled on|final approval on|finalized on"#),
        Rule(.completionDate, #"work completion date|work completed(?: on)?|actual completion date|date work completed"#),
        Rule(.warrantyEnd, #"warranty (?:expires|expiration|end date|expires on|valid until)|coverage ends"#),
        Rule(.receiptDate, #"receipt date|transaction date|payment date"#),
        Rule(.invoiceDate, #"invoice date|date invoiced"#)
    ]
    private static let dateRule = Rule(.receiptDate, "date")
    private static let totals = [
        "receipt": Rule(.receiptTotal, #"grand total|receipt total|total paid|total amount|total"#),
        "invoice": Rule(.invoiceTotal, #"grand total|invoice total|total amount|total"#),
        "estimate": Rule(.estimateTotal, #"grand total|estimate total|quoted total|total estimate|quoted price|proposal price|bid total|total"#)
    ]
    private static let amountRegex = try! Regex(#"^(?:(?:USD|CAD|AUD|EUR|GBP)\s*|[$€£]\s*)?[0-9]{1,12}(?:[,. ][0-9]{3})*(?:[.,][0-9]{2})?(?:\s*(?:USD|CAD|AUD|EUR|GBP))?$"#)

    private static func unambiguousDate(_ value: String) -> String? {
        // An ISO date or a spelled-out month can be checked independently of the reader's locale.
        if value.count == 10, let day = LocalDate(string: value), day.description == value { return value }
        if value.range(of: #"^[A-Za-z0-9, /-]{6,34}$"#, options: .regularExpression) == nil { return nil }
        let us = Locale(identifier: "en_US_POSIX")
        var formats = ["MMMM d, yyyy", "MMM d, yyyy", "MMMM d yyyy", "MMM d yyyy", "d MMMM yyyy", "d MMM yyyy"]
        let parts = value.split(whereSeparator: { $0 == "/" || $0 == "-" })
        if parts.count == 3, parts[2].count == 4, let first = Int(parts[0]), let second = Int(parts[1]) {
            // With two plausible month numbers 03/04 cannot be disambiguated from the document.
            let delimiter = value.contains("/") ? "/" : "-"
            if (13...31).contains(first), (1...12).contains(second) { formats = ["d"+delimiter+"M"+delimiter+"yyyy"] }
            else if (1...12).contains(first), (13...31).contains(second) || first == second {
                formats = ["M"+delimiter+"d"+delimiter+"yyyy"]
            } else { return nil }
        }
        if parts.count != 3 && !value.contains(where: { $0.isLetter }) { return nil }
        let formatter = DateFormatter()
        formatter.locale = us
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
        }
        return nil
    }
}
