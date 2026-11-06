import SwiftUI
import HomeCore

struct ChoreTaskGuide: View {
    @Environment(AppEnvironment.self) private var env
    let idea: MaintenanceIdea
    let mode: Chore.WorkMode
    let country: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(idea.title).font(.subheadline.weight(.semibold))
            if let guide = env.catalog.guide(idea, mode: mode) {
                Text(guide.scope).font(.footnote)
                if country?.uppercased() == "US" || country == nil {
                    Text(guide.priceLabel).font(.subheadline)
                    ForEach(guide.sources, id: \.url) { source in
                        Link(source.label + " · checked " + source.reviewedOn, destination: source.url).font(.footnote)
                    }
                } else { Text("Use a local quote to plan costs in your area.").font(.footnote) }
            } else if country?.uppercased() == "US" || country == nil {
                Text(mode == .diy ? idea.diyScope : idea.detail).font(.footnote)
                if mode == .diy {
                    Text(idea.diyBudget).font(.subheadline)
                    Link("US DIY cost guide", destination: idea.diySource).font(.footnote)
                } else if let cost = idea.costLabel {
                    Text(cost).font(.subheadline)
                    if let source = idea.priceSource { Link(idea.sourceLabel, destination: source).font(.footnote) }
                }
            } else { Text("Use a local quote to plan costs in your area.").font(.footnote) }
        }
    }
}

struct ChoreQuoteRequestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var request: String
    init(title: String) {
        _request = State(initialValue: "Please provide a written estimate for \(title.isEmpty ? "this home maintenance task" : title).\n\nPlease itemize labor, materials and fees, and include your availability and any exclusions.")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Scope to share") { TextEditor(text: $request).frame(minHeight: 155) }
                ShareLink(item: request) { Label("Share estimate request", systemImage: "square.and.arrow.up") }.disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let partner = ProjectReferral(kind: "Contractor") { ProjectReferralLink(partner: partner) }
                Link("Find a remodeler in NARI’s directory", destination: URL(string: "https://remodelingdoneright.nari.org/find-a-remodeler/")!)
            }.navigationTitle("Request an estimate").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
