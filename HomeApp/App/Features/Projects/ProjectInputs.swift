import SwiftUI
import HomeCore

/// Parsing / validation for money and hours text fields (FR-PRJ-02, AC-PRJ-9).
enum ProjectInput {
    enum MoneyResult: Equatable { case empty, value(Money), invalid(String) }

    static let negativeMessage = "Enter an amount of 0 or more"

    /// "$1,234.56", "1234.5", "1 234,56" (locale decimal separator) → whole cents. Negative → invalid.
    static func money(_ text: String, currency: String, locale: Locale = .current) -> MoneyResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        let decimalSep = locale.decimalSeparator ?? "."
        var s = trimmed
        let negative = s.hasPrefix("-") || s.hasPrefix("−") || (s.hasPrefix("(") && s.hasSuffix(")"))
        s = s.filter { $0.isNumber || String($0) == decimalSep || String($0) == "." }
        if decimalSep != "." { s = s.replacingOccurrences(of: decimalSep, with: ".") }
        // More than one "." (e.g. "1.234.56") → treat all but the last as grouping.
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 2 { s = parts.dropLast().joined() + "." + parts.last! }
        guard !s.isEmpty, let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else {
            return .invalid("Enter an amount like 1,250.00")
        }
        if negative { return .invalid(negativeMessage) }
        return .value(Money(major: d, currency: currency))
    }

    /// Hours ≥ 0; empty → nil.
    static func hours(_ text: String) -> Double?? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { return .some(nil) }
        guard let v = Double(t), v >= 0, v.isFinite else { return nil }
        return .some(v)
    }

    static func text(_ m: Money?) -> String {
        guard let m else { return "" }
        return m.cents % 100 == 0 ? String(m.cents / 100) : m.plainString
    }

    static func text(_ h: Double?) -> String {
        guard let h else { return "" }
        return h == h.rounded() ? String(Int(h)) : String(h)
    }
}

/// A labeled money text field with inline validation ("Enter an amount of 0 or more").
struct ProjectMoneyField: View {
    let title: String
    @Binding var text: String
    let currency: String
    /// "From receipt – check" marker (FR-PRJ-22).
    var fromReceipt = false

    private var error: String? {
        if case .invalid(let msg) = ProjectInput.money(text, currency: currency) { return msg }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                HStack(spacing: 4) {
                    Text(currencySymbol).foregroundStyle(.secondary)
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 80)
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            } else if fromReceipt {
                Label("From receipt – check", systemImage: "doc.text.viewfinder").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var currencySymbol: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.currencySymbol ?? currency
    }
}

/// Hours field ("14", "2.5").
struct ProjectHoursField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                HStack(spacing: 4) {
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 60)
                    Text("h").foregroundStyle(.secondary)
                }
            }
            if ProjectInput.hours(text) == nil {
                Text("Enter hours of 0 or more").font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

extension Project.Status {
    /// The four steps of the lifecycle stepper.
    static let lifecycleSteps: [Project.Status] = [.idea, .planned, .inProgress, .done]
}
