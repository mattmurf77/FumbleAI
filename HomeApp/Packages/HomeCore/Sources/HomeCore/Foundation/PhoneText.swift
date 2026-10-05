import Foundation

/// Finds a dialable phone number in free text such as a service contact ("Ace Septic (555) 123-4567").
public enum PhoneText {
    /// The first run of 7–15 digits (spaces, dashes, dots and parentheses allowed between them), as digits with an
    /// optional leading "+". Nil when the text has no phone-like number.
    public static func dialable(in text: String) -> String? {
        var run = ""
        var digits = 0
        func finish() -> String? {
            guard (7...15).contains(digits) else { return nil }
            return (run.hasPrefix("+") ? "+" : "") + run.filter(\.isASCIIDigit)
        }
        for ch in text {
            if ch.isASCIIDigit {
                run.append(ch); digits += 1
            } else if ch == "+" && digits == 0 && run.allSatisfy({ $0 == "(" || $0 == " " }) {
                run = "+"
            } else if " -.()".contains(ch) && (digits > 0 || ch == "(") {
                run.append(ch)
            } else {
                if let n = finish() { return n }
                run = ""; digits = 0
            }
        }
        return finish()
    }

    /// `tel:` URL for the first phone number in `text`.
    public static func telURL(in text: String) -> URL? {
        dialable(in: text).flatMap { URL(string: "tel:\($0)") }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
