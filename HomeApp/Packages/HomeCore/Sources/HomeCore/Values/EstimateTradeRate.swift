import Foundation

/// Published US hourly labor guides. The owner picks the trade, supplies hours, and can override either rate.
public struct EstimateTradeRate: Identifiable, Hashable, Sendable {
    public let title: String
    public let low: Money
    public let high: Money
    public let publisher: String
    public let article: URL
    public var id: String { title }
    public static let checked = "Nov 2026"
    public static let terms = "Local rates vary. Budget for parts separately and ask whether a trip fee covers the first hour. Use your local quote when available."

    private init(_ title: String, dollars: ClosedRange<Int64>, publisher: String, link: String) {
        self.title = title
        low = Money(cents: dollars.lowerBound * 100, currency: "USD")
        high = Money(cents: dollars.upperBound * 100, currency: "USD")
        self.publisher = publisher
        article = URL(string: link)!
    }

    public static let handyman = Self("Independent handyman", dollars: 50...80, publisher: "HomeGuide", link: "https://homeguide.com/costs/handyman-prices")
    public static let carpenter = Self("Carpenter", dollars: 40...100, publisher: "Angi", link: "https://www.angi.com/articles/carpenter-cost.htm")
    public static let plumber = Self("Plumber", dollars: 45...200, publisher: "Angi", link: "https://www.angi.com/articles/plumber-cost.htm")
    public static let electrician = Self("Electrician", dollars: 50...130, publisher: "HomeGuide", link: "https://homeguide.com/costs/electrician-cost-per-hour")
    public static let options: [Self] = [.handyman, .carpenter, .plumber, .electrician]

    public var sourceNote: String {
        "\(publisher) · \(title) · US hourly labor guide, checked \(Self.checked). \(Self.terms) \(article.absoluteString)"
    }

    public static func available(mode: Chore.WorkMode, kind: WorkEstimateLine.Kind, unit: String, currency: String, country: String?) -> Bool {
        let countryCode = country?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hours = ["h", "hr", "hrs", "hour", "hours"].contains(ChoreSupply.normalize(unit))
        return mode == .hirePro && kind == .labor && hours && currency == "USD" && countryCode == "US"
    }

    /// If owners replace a guided rate and supply no new terms, avoid attributing their new number to the publisher.
    public static func sourceAfterEditing(_ basis: String, low: Money?, high: Money?) -> String? {
        let note = basis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guide = options.first(where: { $0.sourceNote == note }) else { return note.isEmpty ? nil : note }
        if low == guide.low && high == guide.high { return note }
        return low == nil && high == nil ? nil : "Owner-edited hourly rate."
    }
}
