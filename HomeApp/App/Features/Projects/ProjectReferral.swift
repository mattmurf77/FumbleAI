import SwiftUI

/// An outbound handoff is shown only when the publisher has supplied an approved partner
/// and a disclosure for the specific product. User/property data is never appended to a URL.
struct ProjectReferral {
    let name: String
    let disclosure: String
    let url: URL

    init?(kind: String, info: [String: Any]? = Bundle.main.infoDictionary) {
        func value(_ key: String) -> String? {
            guard let text = info?["Home" + kind + key] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
        }
        guard let name = value("PartnerName"), let disclosure = value("PartnerDisclosure"),
              let location = value("PartnerURL"), let url = URL(string: location),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        self.name = name
        self.url = url
        self.disclosure = disclosure
    }
}

struct ProjectReferralLink: View {
    let partner: ProjectReferral
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(partner.disclosure).font(.footnote).foregroundStyle(.secondary)
            Link(destination: partner.url) { Label("Visit " + partner.name, systemImage: "arrow.up.right.square") }
            Text(partner.url.host ?? partner.name).font(.caption).foregroundStyle(.secondary)
        }
    }
}
