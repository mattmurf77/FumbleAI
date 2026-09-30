import Foundation
import PlanKit
import HomeCore

/// Deterministic, locale-independent formatting for canvas text (chips and the summary strip).
public enum LensFormat {
    /// "$5,810" (whole major units, grouped).
    public static func money(_ cents: Int64, currency: String = "USD") -> String {
        let neg = cents < 0
        let units = (abs(cents) + 50) / 100
        return (neg ? "-" : "") + symbol(currency) + grouped(units)
    }

    /// "$4.2k", "$950", "$18k" (HomeCore `Money.compact`).
    public static func compact(_ cents: Int64, currency: String = "USD") -> String {
        Money(cents: cents, currency: currency).compact
    }

    public static func grouped(_ n: Int64) -> String {
        let s = String(abs(n))
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    public static func grouped(_ n: Int) -> String { grouped(Int64(n)) }

    public static func symbol(_ code: String) -> String {
        switch code { case "USD", "CAD", "AUD", "NZD": return "$"; case "EUR": return "€"; case "GBP": return "£"; default: return code + " " }
    }

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Mar ’26".
    public static func monthYear(_ d: LocalDate) -> String {
        let m = monthNames[max(0, min(11, d.month - 1))]
        return "\(m) ’\(String(format: "%02d", d.year % 100))"
    }

    /// "Oct 2".
    public static func monthDay(_ d: LocalDate) -> String {
        "\(monthNames[max(0, min(11, d.month - 1))]) \(d.day)"
    }

    /// "1,240 sq ft" / "115 m²".
    public static func area(_ sqIn: Double, system: UnitSystem) -> String {
        HomeLengthFormatter.formatArea(squareInches: sqIn, system: system)
    }

    /// Replaces ASCII feet/inch marks with primes for display (`13′2″ × 11′6″`).
    public static func primes(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "′").replacingOccurrences(of: "\"", with: "″")
    }

    /// "1 item" / "3 items".
    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : (plural ?? singular + "s"))
    }
}
