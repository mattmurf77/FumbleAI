import SwiftUI
import HomeCore

/// The owner chooses whether the old scope fits this job. Original documents and actual spending stay unchanged.
struct EstimateRecordPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    let propertyId: UUID
    let currency: String
    let title: String
    let choose: (WorkEstimateLine) -> Void
    @State private var history: [HomeHistoryEntry]?
    @State private var quotes: [HomeDocument]?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if let history, let quotes {
                    let options = EstimateReference.options(history: history, quotes: quotes, currency: currency)
                    let matches = options.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                    if matches.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "No recorded prices in " + currency : "No matching records",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Save a completed project cost or a written estimate to use it here."))
                    } else {
                        let related = matches.filter { $0.isRelated(to: title) }
                        let others = matches.filter { !$0.isRelated(to: title) }
                        if !related.isEmpty { Section("Similar names") { rows(related) } }
                        if !others.isEmpty { Section("Other work at this home") { rows(others) } }
                    }
                } else { ProgressView("Checking your records…") }
            }
            .navigationTitle("Use a recorded cost")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search jobs and written quotes")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task(id: propertyId) {
            for await values in env.projects.observeHistory(propertyId: propertyId) { history = values }
        }
        .task(id: propertyId) {
            for await values in env.attachments.observeDocuments(propertyId: propertyId) { quotes = values }
        }
    }

    private func rows(_ records: [EstimateReference]) -> some View {
        ForEach(records) { record in
            Button {
                choose(record.estimateLine)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(.headline)
                    Text(record.amount.formatted() + " · " + record.kind.rawValue).foregroundStyle(.secondary)
                    if let date = record.date { Text(date).font(.caption).foregroundStyle(.secondary) }
                }
            }.accessibilityIdentifier("estimate.reference." + record.id)
        }
    }
}

struct EstimateReference: Identifiable {
    enum Kind: String { case completed = "Actual cost", quote = "Written quote" }
    let id: String
    let title: String
    let kind: Kind
    let date: String?
    let amount: Money

    var estimateLine: WorkEstimateLine {
        let dateLabel = date.map { " · " + $0 } ?? " · Date unrecorded"
        return WorkEstimateLine(kind: .wholeJob, name: title, quantity: 1, unit: "job", unitPrice: amount,
            source: kind.rawValue + " from your home records" + dateLabel + ". Whole-job comparison. Check that today's scope and prices are comparable.")
    }

    static func options(history: [HomeHistoryEntry], quotes: [HomeDocument], currency: String) -> [Self] {
        let actuals = history.compactMap { record -> Self? in
            guard let amount = record.actual, amount.currency == currency, amount.cents >= 0 else { return nil }
            return Self(id: "work-" + record.id.uuidString, title: record.title, kind: .completed,
                        date: record.date?.description ?? record.completedYear.map(String.init), amount: amount)
        }
        let pricedQuotes = quotes.compactMap { record -> Self? in
            guard record.attachment.deletedAt == nil, record.details.category == .estimate,
                  let amount = record.details.quoteAmount, amount.currency == currency, amount.cents >= 0 else { return nil }
            return Self(id: "quote-" + record.id.uuidString, title: record.details.title, kind: .quote,
                        date: record.details.documentDate?.description, amount: amount)
        }
        return (actuals + pricedQuotes).sorted {
            if $0.date != $1.date { return ($0.date ?? "") > ($1.date ?? "") }
            return ($0.title, $0.id) < ($1.title, $1.id)
        }
    }

    func isRelated(to job: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 })
                .subtracting(["for", "the", "work", "need", "get", "replace", "install", "with", "and", "our", "some"])
        }
        return !words(title).isDisjoint(with: words(job))
    }
}
