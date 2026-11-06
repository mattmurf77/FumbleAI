import Foundation

/// Public planning content. Home records and recommendation ranking stay on the device.
/// A catalog is accepted as one validated snapshot, so prices never lose their source or scope.
public struct HomeContentCatalog: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public let label: String
        public let url: URL
        public let reviewedOn: String
    }
    public struct Guide: Codable, Equatable, Sendable {
        public let id: String
        public let lowMinor: Int64
        public let highMinor: Int64
        public let country: String
        public let currency: String
        public let unit: String
        public let basis: String
        public let scope: String
        public let sources: [Source]

        public var priceLabel: String {
            let low = Money(cents: lowMinor, currency: currency).formatted(showCents: lowMinor % 100 != 0)
            let high = Money(cents: highMinor, currency: currency).formatted(showCents: highMinor % 100 != 0)
            let suffix: String
            switch unit {
            case "hour": suffix = "/hour"
            case "squareFoot": suffix = "/sq ft"
            case "cubicYard": suffix = "/cu yd"
            case "job", "visit": suffix = ""
            default: suffix = "/" + unit
            }
            return low + "–" + high + " " + currency + suffix
        }
        public var sourceLabel: String {
            sources.map { $0.label + " · checked " + $0.reviewedOn }.joined(separator: "; ")
        }
    }
    public struct Supply: Codable, Equatable, Sendable {
        public let name: String
        public let quantity: Int
        public let unit: String
        public let isEquipment: Bool
        public var suggestion: ChoreSupply {
            .init(name: name, quantity: quantity, unit: unit, isEquipment: isEquipment)
        }
    }
    public struct Recommendation: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        public let symbol: String
        public let diyTitle: String
        public let supplies: [Supply]
        public let professionalGuideID: String
        public let diyGuideID: String
        public let providerDirectoryID: String
        public let resaleAssumptionID: String?
    }
    public struct Directory: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let url: URL
        public let disclosure: String
    }
    public struct ResaleAssumption: Codable, Equatable, Sendable {
        public let id: String
        public let ratioBasisPoints: Int
        public let country: String
        public let currency: String
        public let mode: String
        public let costGuideID: String
        public let scope: String
        public let source: Source
    }
    public let schemaVersion: Int
    public let version: String
    public let publishedAt: String
    public let reviewedOn: String
    public let recommendations: [Recommendation]
    public let costGuides: [Guide]
    public let providerDirectories: [Directory]
    public let resaleAssumptions: [ResaleAssumption]
    /// Schema 1 never enables compensated referrals through a remote content change.
    public struct DisabledReferral: Codable, Equatable, Sendable {}
    public let referralPartners: [DisabledReferral]

    public static let maximumBytes = 512 * 1024
    public enum Invalid: Error { case content }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw Invalid.content }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try catalog.validate()
        return catalog
    }

    public func validate() throws {
        func text(_ value: String, _ max: Int = 200) -> Bool {
            !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && value.count <= max &&
                !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        func date(_ value: String) -> Bool { LocalDate(string: value)?.description == value }
        func identifier(_ value: String) -> Bool { value.range(of: "^[A-Za-z][A-Za-z0-9._-]{0,79}$", options: .regularExpression) != nil }
        func safeURL(_ url: URL) -> Bool {
            guard let host = url.host, url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, url.fragment == nil, url.absoluteString.count <= 2048,
                  host.range(of: "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\\.[a-z]{2,}$", options: [.regularExpression, .caseInsensitive]) != nil,
                  host.range(of: "(?:^|\\.)(?:localhost|local|internal|test|invalid|example)$", options: [.regularExpression, .caseInsensitive]) == nil
            else { return false }
            return true
        }
        guard schemaVersion == 1, text(version, 80), date(reviewedOn), publicationDate != nil,
              version.range(of: "^\\d{4}-\\d{2}-\\d{2}\\.[1-9]\\d{0,5}$", options: .regularExpression) != nil,
              String(version.prefix(10)) == String(publishedAt.prefix(10)), reviewedOn <= String(publishedAt.prefix(10)),
              publishedAt.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$", options: .regularExpression) != nil,
              referralPartners.isEmpty,
              recommendations.count == MaintenanceIdea.allCases.count,
              Set(recommendations.map(\.id)) == Set(MaintenanceIdea.allCases.map(\.rawValue)),
              (12...100).contains(costGuides.count), Set(costGuides.map(\.id)).count == costGuides.count
        else { throw Invalid.content }
        for guide in costGuides {
            guard identifier(guide.id), guide.lowMinor >= 0, guide.highMinor >= guide.lowMinor,
                  guide.highMinor <= 1_000_000_000, guide.country == "US", guide.currency == "USD",
                  ["job", "hour", "item", "gallon", "carton", "bag", "squareFoot", "cubicYard", "visit"].contains(guide.unit),
                  ["installed", "materials", "labor", "wholeJob", "retailExample"].contains(guide.basis),
                  text(guide.scope, 2000), (1...8).contains(guide.sources.count), Set(guide.sources.map(\.url)).count == guide.sources.count,
                  guide.sources.allSatisfy({ text($0.label, 200) && date($0.reviewedOn) && $0.reviewedOn <= reviewedOn && safeURL($0.url) })
            else { throw Invalid.content }
        }
        let guides = Set(costGuides.map(\.id))
        guard (1...20).contains(providerDirectories.count), resaleAssumptions.count <= 1,
              Set(providerDirectories.map(\.id)).count == providerDirectories.count,
              Set(resaleAssumptions.map(\.id)).count == resaleAssumptions.count else { throw Invalid.content }
        for directory in providerDirectories {
            guard identifier(directory.id), text(directory.name, 120), safeURL(directory.url), text(directory.disclosure, 1000)
            else { throw Invalid.content }
        }
        for assumption in resaleAssumptions {
            guard identifier(assumption.id), (0...30_000).contains(assumption.ratioBasisPoints),
                  assumption.mode == "hirePro", assumption.country == "US", assumption.currency == "USD",
                  assumption.costGuideID == "closet-professional", guides.contains(assumption.costGuideID), text(assumption.scope, 2000),
                  text(assumption.source.label, 200), date(assumption.source.reviewedOn), assumption.source.reviewedOn <= reviewedOn, safeURL(assumption.source.url)
            else { throw Invalid.content }
        }
        for idea in recommendations {
            guard text(idea.title, 120), text(idea.diyTitle, 120), text(idea.detail, 2000),
                  idea.symbol.range(of: "^[a-z][a-z0-9.]{0,79}$", options: .regularExpression) != nil,
                  guides.contains(idea.professionalGuideID), guides.contains(idea.diyGuideID),
                  idea.professionalGuideID == idea.id + "-professional", idea.diyGuideID == idea.id + "-diy",
                  let professional = costGuides.first(where: { $0.id == idea.professionalGuideID }),
                  let diy = costGuides.first(where: { $0.id == idea.diyGuideID }),
                  professional.unit == (idea.id == "filter" ? "hour" : "job"),
                  professional.basis == (idea.id == "filter" ? "labor" : "installed"),
                  diy.unit == "item", ["materials", "retailExample"].contains(diy.basis),
                  !idea.supplies.isEmpty, idea.supplies.count <= 75,
                  idea.supplies.allSatisfy({ $0.unit == "ea" && text($0.name, 120) }),
                  providerDirectories.contains(where: { $0.id == idea.providerDirectoryID }),
                  idea.resaleAssumptionID == nil || resaleAssumptions.contains(where: {
                      idea.id == "closet" && $0.id == idea.resaleAssumptionID && $0.costGuideID == idea.professionalGuideID
                  })
            else { throw Invalid.content }
            try ChoreSupply.validate(idea.supplies.map(\.suggestion))
        }
    }

    public var publicationDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: publishedAt) ?? ISO8601DateFormatter().date(from: publishedAt)
    }

    public func recommendation(_ idea: MaintenanceIdea) -> Recommendation? {
        recommendations.first { $0.id == idea.rawValue }
    }
    public func guide(for idea: MaintenanceIdea, mode: Chore.WorkMode) -> Guide? {
        guard let entry = recommendation(idea) else { return nil }
        let id = mode == .diy ? entry.diyGuideID : entry.professionalGuideID
        return costGuides.first { $0.id == id }
    }
    public func directory(for idea: MaintenanceIdea) -> Directory? {
        providerDirectories.first { $0.id == recommendation(idea)?.providerDirectoryID }
    }
    public func resaleAssumption(for idea: MaintenanceIdea) -> ResaleAssumption? {
        resaleAssumptions.first { $0.id == recommendation(idea)?.resaleAssumptionID }
    }
    public func resaleScenario(for idea: MaintenanceIdea, mode: Chore.WorkMode) -> ClosedRange<Int>? {
        guard mode == .hirePro, let assumption = resaleAssumption(for: idea),
              let guide = guide(for: idea, mode: mode) else { return nil }
        // This illustrative cost-recovery scenario is rounded to hundreds of dollars, as in the bundled guide.
        func rounded(_ cents: Int64) -> Int {
            Int((Double(cents) * Double(assumption.ratioBasisPoints) / 100_000_000).rounded()) * 100
        }
        return rounded(guide.lowMinor)...rounded(guide.highMinor)
    }
}
