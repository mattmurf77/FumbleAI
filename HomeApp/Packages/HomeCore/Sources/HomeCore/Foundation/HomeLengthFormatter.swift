import Foundation
import PlanKit

public enum UnitSystem: String, ForwardCompatibleEnum {
    case imperial, metric, unknown
    public static var unknownCase: UnitSystem { .unknown }
}

/// Formats and parses lengths/areas. Storage is always inches (LLD §1); display follows `UnitSystem`.
public enum HomeLengthFormatter {
    public static let inchesPerMeter = 39.3701

    /// `12'4"` (imperial, nearest inch) or `3.76 m` / `85 cm` (metric).
    public static func format(_ inches: Double, system: UnitSystem = .imperial) -> String {
        guard inches.isFinite else { return "–" }
        switch system {
        case .metric:
            let m = inches / inchesPerMeter
            if abs(m) < 1 { return "\(Int((m * 100).rounded())) cm" }
            return String(format: "%.2f m", m)
        case .imperial, .unknown:
            let total = Int(inches.rounded())
            let sign = total < 0 ? "-" : ""
            let a = abs(total)
            return "\(sign)\(a / 12)'\(a % 12)\""
        }
    }

    /// Inches with quarter fractions: `35¾ in`, `32 in`; metric: `91 cm`.
    public static func formatInches(_ inches: Double, system: UnitSystem = .imperial) -> String {
        guard inches.isFinite else { return "–" }
        if system == .metric { return "\(Int((inches / inchesPerMeter * 100).rounded())) cm" }
        let quarters = Int((abs(inches) * 4).rounded())
        let whole = quarters / 4
        let frac = ["", "¼", "½", "¾"][quarters % 4]
        let sign = inches < 0 && quarters > 0 ? "-" : ""
        return whole == 0 && !frac.isEmpty ? "\(sign)\(frac) in" : "\(sign)\(whole)\(frac) in"
    }

    /// `12'4" × 14'0"`.
    public static func formatDims(_ w: Double, _ h: Double, system: UnitSystem = .imperial) -> String {
        "\(format(w, system: system)) × \(format(h, system: system))"
    }

    /// Room label dimension text (§6.7): rectangles → `W × H`; other shapes → bbox prefixed "~";
    /// approximate rooms always get "~".
    public static func dimensionText(for polygon: Polygon, isApproximate: Bool, system: UnitSystem = .imperial) -> String {
        if let r = polygon.rectangleSize {
            let s = formatDims(r.width, r.height, system: system)
            return isApproximate ? "~" + s : s
        }
        let b = polygon.bounds
        return "~" + formatDims(b.width, b.height, system: system)
    }

    /// `1,240 sq ft` or `115 m²`.
    public static func formatArea(squareInches a: Double, system: UnitSystem = .imperial) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "en_US")
        switch system {
        case .metric: return (f.string(from: NSNumber(value: Area.squareMeters(fromSquareInches: a))) ?? "0") + " m²"
        default: return (f.string(from: NSNumber(value: Area.squareFeet(fromSquareInches: a))) ?? "0") + " sq ft"
        }
    }

    /// Parses typed dimensions into inches (§6.8): `12'4"`, `12' 4`, `12.33'`, `148"`, `148in`, `3.76m`,
    /// `376cm`, `12ft 4in`. A bare number is interpreted in `bareUnit` (inches by default; pass `.metric`
    /// to read bare numbers as centimeters).
    public static func parse(_ text: String, bareUnit: UnitSystem = .imperial) -> Double? {
        var s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "′", with: "'")
            .replacingOccurrences(of: "”", with: "\"").replacingOccurrences(of: "″", with: "\"")
            .replacingOccurrences(of: "''", with: "\"").replacingOccurrences(of: ",", with: ".")
        func num(_ t: Substring) -> Double? { Double(t.trimmingCharacters(in: .whitespaces)) }

        if s.hasSuffix("mm"), let v = num(s.dropLast(2)) { return v / 10 / 100 * inchesPerMeter }
        if s.hasSuffix("cm"), let v = num(s.dropLast(2)) { return v / 100 * inchesPerMeter }
        if s.hasSuffix("m"), !s.hasSuffix("mm"), let v = num(s.dropLast(1)) { return v * inchesPerMeter }

        // Normalize feet/inch words.
        s = s.replacingOccurrences(of: "feet", with: "'").replacingOccurrences(of: "foot", with: "'")
            .replacingOccurrences(of: "ft", with: "'").replacingOccurrences(of: "inches", with: "\"")
            .replacingOccurrences(of: "inch", with: "\"").replacingOccurrences(of: "in", with: "\"")

        if let q = s.firstIndex(of: "'") {
            guard let feet = num(s[..<q]) else { return nil }
            var rest = s[s.index(after: q)...].trimmingCharacters(in: .whitespaces)
            if rest.hasSuffix("\"") { rest.removeLast() }
            if rest.isEmpty { return feet * 12 }
            guard let inches = Double(rest.trimmingCharacters(in: .whitespaces)), !rest.contains("'") else { return nil }
            return feet * 12 + inches
        }
        if s.hasSuffix("\""), let v = num(s.dropLast()) { return v }
        if let v = Double(s) { return bareUnit == .metric ? v / 100 * inchesPerMeter : v }
        return nil
    }
}
