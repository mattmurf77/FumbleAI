import SwiftUI
import HomeCore
import PDFKit
import CoreTransferable
import UniformTypeIdentifiers

struct HomeBriefBuilder: View {
    @Environment(AppEnvironment.self) private var env
    @EnvironmentObject private var billing: BlueprintBilling
    let propertyId: UUID
    @State private var journal: HomeValueSnapshot?
    @State private var selected = Set<UUID>()
    @State private var includeCosts = false
    @State private var preview: BriefFile?
    @State private var busy = false
    @State private var problem: String?
    @State private var attempt = 0
    @State private var unavailable = false

    var body: some View {
        Form {
            if !billing.unlocked { HomeBriefPurchaseView() }
            else if let journal {
                Section {
                    if journal.investments.isEmpty {
                        Text("Record past work in Home value, then choose the projects you want to share.").foregroundStyle(.secondary)
                    }
                    ForEach(journal.investments) { work in
                        Toggle(isOn: Binding(get: { selected.contains(work.id) }, set: { value in
                            if value { selected.insert(work.id) } else { selected.remove(work.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(work.title)
                                if let date = work.date { Text(ScheduleFormat.longDay(date)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.accessibilityIdentifier("brief.project.\(work.id.uuidString)")
                    }
                } header: { Text("Choose completed work") } footer: { Text("Your PDF includes the titles and dates you select. Review project titles for personal details before sharing.") }
                Section {
                    Toggle("Include recorded costs", isOn: $includeCosts)
                    Button { Task { await prepare(journal) } } label: {
                        if busy { ProgressView("Preparing PDF…") } else { Label("Preview PDF", systemImage: "doc.text.magnifyingglass") }
                    }.disabled(selected.isEmpty).accessibilityIdentifier("brief.preview")
                }
            } else if unavailable { Button("Reload completed work") { attempt += 1 } }
            else { ProgressView("Loading completed work…") }
        }
        .disabled(busy)
        .navigationTitle("Home Brief")
        .task(id: "\(propertyId)-\(attempt)") {
            unavailable = false
            for await value in env.homeValue.observe(propertyId: propertyId) {
                journal = value; selected.formIntersection(value.investments.map(\.id))
            }
            if !Task.isCancelled { journal = nil; unavailable = true }
        }
        .sheet(item: $preview) { file in NavigationStack { if billing.unlocked { HomeBriefPreview(file: file) } } }
        .onChange(of: billing.unlocked) { _, unlocked in if !unlocked { preview = nil } }
        .alert("Couldn’t create Home Brief", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} } message: { Text(problem ?? "") }
    }
    @MainActor private func prepare(_ journal: HomeValueSnapshot) async {
        guard billing.unlocked, !busy else { return }
        busy = true; defer { busy = false }
        let ids = selected, costs = includeCosts, date = env.clock.today
        do {
            let data = try await Task.detached(priority: .userInitiated) { try HomeBriefPDF.make(from: journal.investments, selected: ids, includeCosts: costs, prepared: date) }.value
            if billing.unlocked { preview = BriefFile(data: data) }
        } catch { problem = error.localizedDescription }
    }
}

private struct BriefFile: Identifiable, Transferable {
    let id = UUID()
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { file in file.data }.suggestedFileName("Home improvement brief.pdf")
    }
}

private struct HomeBriefPreview: View {
    @EnvironmentObject private var billing: BlueprintBilling
    @Environment(\.dismiss) private var dismiss
    let file: BriefFile
    var body: some View {
        PDFDisplay(bytes: file.data)
            .navigationTitle("Preview brief").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if billing.unlocked {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: file, preview: SharePreview("Home improvement brief")) { Label("Share PDF", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("brief.share")
                    }
                }
            }
    }
}

private struct PDFDisplay: UIViewRepresentable {
    let bytes: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayDirection = .vertical
        view.document = PDFDocument(data: bytes); return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}
