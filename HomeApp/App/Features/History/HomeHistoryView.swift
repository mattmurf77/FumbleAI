import SwiftUI
import HomeCore

struct HomeHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    let property: Property
    @State private var history: [HomeHistoryEntry]?
    @State private var logging = false
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        List {
            if let history {
                Section {
                    Button { logging = true } label: { Label("Record past work", systemImage: "plus.circle") }
                        .accessibilityIdentifier("history.log")
                    NavigationLink { BringRecordsView(property: property) } label: { Label("Import records and documents", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("history.intake")
                    NavigationLink { HomeBriefBuilder(propertyId: property.id) } label: { Label("Home Brief", systemImage: "doc.richtext") }
                        .accessibilityIdentifier("history.homeBrief")
                } footer: { Text("Keep a record for yourself, or choose completed projects for a PDF to share with a contractor or insurer.") }
                if history.isEmpty {
                    ContentUnavailableView("No completed work yet", systemImage: "hammer", description: Text("Start with a repair or improvement you remember. Add the cost or a receipt when you have it."))
                } else {
                    let known = history.compactMap(\.actual)
                    let groups = Dictionary(grouping: known, by: \.currency)
                    Section("Recorded spending") {
                        ForEach(groups.keys.sorted(), id: \.self) { code in
                            let total = groups[code, default: []].reduce(Decimal.zero) { $0 + $1.decimal }
                            LabeledContent(code, value: total.formatted(.currency(code: code)))
                        }
                        let missing = history.count - known.count
                        if missing > 0 { Text(missing == 1 ? "One project has no recorded cost." : "\(missing) projects have no recorded cost.").foregroundStyle(.secondary) }
                    }
                    Section("Completed work") {
                        ForEach(history) { work in
                            NavigationLink { ProjectDetailView(projectID: work.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(work.title).font(.headline)
                                    Text([work.date.map(ScheduleFormat.longDay) ?? work.completedYear.map(String.init) ?? "Completion date unrecorded", work.actual.map { $0.formatted() + " " + $0.currency } ?? "Cost unrecorded"].joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                                    if work.fileCount > 0 {
                                        Label(work.evidenceText, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else if failed {
                ContentUnavailableView { Label("History unavailable", systemImage: "exclamationmark.circle") } actions: { Button("Try again") { retry += 1 } }
            } else { ProgressView("Loading home history…") }
        }
        .navigationTitle("Home history").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $logging) { ProjectForm(spaceID: nil, levelID: nil, initialStatus: .done) }
        .task(id: "\(property.id)-\(retry)") {
            history = nil; failed = false
            for await next in env.projects.observeHistory(propertyId: property.id) { history = next }
            if !Task.isCancelled { history = nil; failed = true }
        }
    }
}

extension HomeHistoryEntry {
    var evidenceText: String {
        let count = fileCount == 1 ? "1 file" : "\(fileCount) files"
        return hasReceipt ? count + " · Receipt on file" : count
    }
}
