import Foundation

/// Owner-selected planning assumptions. These results never enter actual costs or a home valuation.
public enum ProjectScenarios {
    public static func recoveredCost(_ cost: Money, percent: Decimal) -> Money? {
        guard cost.cents >= 0, !percent.isNaN, percent >= 0, percent <= 200 else { return nil }
        var cents = Decimal(cost.cents) * percent / 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .plain)
        guard rounded <= Decimal(Int64.max) else { return nil }
        return Money(cents: NSDecimalNumber(decimal: rounded).int64Value, currency: cost.currency)
    }

    /// Fully amortizing fixed-rate loan with equal monthly payments and no additional fees.
    public static func monthlyPayment(principal: Money, annualRate: Double, months: Int) -> Money? {
        guard principal.cents > 0, annualRate.isFinite, (0...100).contains(annualRate),
              (1...480).contains(months) else { return nil }
        let r = annualRate / 1200
        let cents = r == 0 ? Double(principal.cents) / Double(months)
            : Double(principal.cents) * r / -expm1(-Double(months) * log1p(r))
        guard cents.isFinite, cents >= 0, cents.rounded() < Double(Int64.max) else { return nil }
        return Money(cents: Int64(cents.rounded()), currency: principal.currency)
    }
}
