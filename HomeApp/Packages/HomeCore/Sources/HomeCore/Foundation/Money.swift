import Foundation

/// Money in minor units (cents) plus an ISO 4217 currency code. Never a float. LLD §1.
public struct Money: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var cents: Int64
    public var currency: String

    public init(cents: Int64, currency: String = "USD") { self.cents = cents; self.currency = currency }

    /// From major units, e.g. `Money(major: 4612.5)` → 461250 cents. Rounds half away from zero.
    public init(major: Decimal, currency: String = "USD") {
        var v = major * 100
        var r = Decimal()
        NSDecimalRound(&r, &v, 0, .plain)
        self.cents = NSDecimalNumber(decimal: r).int64Value
        self.currency = currency
    }

    public static func zero(_ currency: String = "USD") -> Money { Money(cents: 0, currency: currency) }

    public var isZero: Bool { cents == 0 }
    public var decimal: Decimal { Decimal(cents) / 100 }
    public var majorUnits: Double { Double(cents) / 100 }

    /// Plain decimal string with 2 places, e.g. "4612.00" (CSV export format, LLD §13).
    public var plainString: String {
        let sign = cents < 0 ? "-" : ""
        let a = cents.magnitude
        return "\(sign)\(a / 100).\(String(format: "%02d", Int(a % 100)))"
    }

    public var description: String { "\(plainString) \(currency)" }

    /// Localized currency string, e.g. "$4,612.00".
    public func formatted(locale: Locale = .current, showCents: Bool = true) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = locale
        if !showCents { f.maximumFractionDigits = 0; f.minimumFractionDigits = 0 }
        return f.string(from: NSDecimalNumber(decimal: decimal)) ?? plainString
    }

    /// Compact chip text: "$950", "$4.2k", "$18k", "$1.3M". Uses the currency symbol for USD/EUR/GBP, else the code.
    public var compact: String {
        let sym = Money.symbol(for: currency)
        let v = abs(majorUnits)
        let sign = cents < 0 ? "-" : ""
        let body: String
        switch v {
        case ..<1000: body = String(Int(v.rounded()))
        case ..<10_000: body = Money.trim(String(format: "%.1f", v / 1000)) + "k"
        case ..<1_000_000: body = String(Int((v / 1000).rounded())) + "k"
        default: body = Money.trim(String(format: "%.1f", v / 1_000_000)) + "M"
        }
        return sign + sym + body
    }

    static func trim(_ s: String) -> String { s.hasSuffix(".0") ? String(s.dropLast(2)) : s }
    static func symbol(for code: String) -> String {
        switch code { case "USD", "CAD", "AUD", "NZD": return "$"; case "EUR": return "€"; case "GBP": return "£"; default: return code + " " }
    }

    public static func + (a: Money, b: Money) -> Money { Money(cents: a.cents + b.cents, currency: a.currency) }
    public static func - (a: Money, b: Money) -> Money { Money(cents: a.cents - b.cents, currency: a.currency) }
    public static func += (a: inout Money, b: Money) { a = a + b }
    public static func < (a: Money, b: Money) -> Bool { a.cents < b.cents }
}
