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
        if trimmed.contains("-") || trimmed.contains("−") || trimmed.first == "(" { return .invalid(negativeMessage) }
        let invalid = MoneyResult.invalid("Enter a positive amount with up to two decimal places")
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        var number = trimmed
        for symbol in [currency, formatter.currencySymbol ?? ""] where !symbol.isEmpty {
            if number.hasPrefix(symbol) { number.removeFirst(symbol.count) }
            else if number.hasSuffix(symbol) { number.removeLast(symbol.count) }
            number = number.trimmingCharacters(in: .whitespaces)
        }
        let decimal = locale.decimalSeparator ?? "."
        let grouping = locale.groupingSeparator ?? ","
        if grouping.trimmingCharacters(in: .whitespaces).isEmpty {
            for space in [" ", "\u{a0}", "\u{202f}"] { number = number.replacingOccurrences(of: space, with: grouping) }
        }
        if number.hasPrefix(decimal) { number = "0" + number }
        let parts = number.components(separatedBy: decimal)
        guard parts.count <= 2 else { return invalid }
        let groups = parts[0].components(separatedBy: grouping)
        let digits = CharacterSet(charactersIn: "0123456789")
        func isDigits(_ value: String) -> Bool { !value.isEmpty && value.unicodeScalars.allSatisfy(digits.contains) }
        guard groups.allSatisfy(isDigits) else { return invalid }
        if groups.count > 1 {
            let size = max(formatter.groupingSize, 1)
            let secondary = formatter.secondaryGroupingSize > 0 ? formatter.secondaryGroupingSize : size
            guard groups[0].count <= secondary, groups.last?.count == size,
                  groups.dropFirst().dropLast().allSatisfy({ $0.count == secondary }) else { return invalid }
        }
        if parts.count == 2, !isDigits(parts[1]) || parts[1].count > 2 { return invalid }
        let canonical = groups.joined() + (parts.count == 2 ? "." + parts[1] : "")
        guard canonical.count <= 20, let d = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")),
              d <= Decimal(Int64.max) / 100 else { return invalid }
        return .value(Money(major: d, currency: currency))
    }

    /// Hours ≥ 0; empty → nil.
    static func hours(_ text: String) -> Double?? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { return .some(nil) }
        guard let v = Double(t), v >= 0, v.isFinite, v <= 10_000_000 else { return nil }
        return .some(v)
    }

    static func text(_ m: Money?) -> String {
        guard let m else { return "" }
        return m.decimal.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    static func text(_ h: Double?) -> String {
        guard let h else { return "" }
        if h == h.rounded(), let integer = Int(exactly: h) { return String(integer) }
        return String(h)
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
                Text("Enter between 0 and 10,000,000 hours").font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

extension Project.Status {
    /// The four steps of the lifecycle stepper.
    static let lifecycleSteps: [Project.Status] = [.idea, .planned, .inProgress, .done]
}


struct ProjectWorkActionPicker: View {
    @Binding var selection: Project.WorkAction?

    var body: some View {
        Picker("Type of work", selection: $selection) {
            Text("Unspecified").tag(Project.WorkAction?.none)
            ForEach(Project.WorkAction.knownCases, id: \.self) { action in
                Text(action.displayName).tag(Optional(action))
            }
        }
        .accessibilityIdentifier("project.workAction")
    }
}
