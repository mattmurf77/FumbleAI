import SwiftUI
import HomeCore
import QuickLook
import VisionKit
import UniformTypeIdentifiers

struct HomeDocumentsView: View {
    @Environment(AppEnvironment.self) private var env
    let property: Property
    let projectId: UUID?
    let initialCategory: HomeDocumentCategory?
    init(property: Property, projectId: UUID? = nil, initialCategory: HomeDocumentCategory? = nil) {
        self.property = property; self.projectId = projectId; self.initialCategory = initialCategory
        _category = State(initialValue: initialCategory)
    }
    @State private var documents: [HomeDocument]?
    @State private var query = ""
    @State private var category: HomeDocumentCategory?
    @State private var importing = false
    @State private var scanning = false
    @State private var preparing = false
    @State private var source: DocumentSource?
    @State private var problem: String?
    @State private var retry = 0
    @State private var failed = false

    var body: some View {
        List {
            if preparing { ProgressView("Opening document…") }
            if let documents {
                if documents.isEmpty {
                    ContentUnavailableView { Label("Keep your home documents", systemImage: "folder") } description: { Text("File permits, insurance policies, appliance warranties and invoices here. Link them to a project whenever it helps.") } actions: { importButton }
                } else {
                    let filtered = documents.filter { (projectId == nil || $0.linkedProjectId == projectId) && $0.matches(query) && (category == nil || $0.details.category == category) }
                    if filtered.isEmpty { ContentUnavailableView("No matching documents", systemImage: "magnifyingglass", description: Text("Try another search or choose All types.")) }
                    ForEach(filtered) { doc in
                        NavigationLink { HomeDocumentDetail(id: doc.id, propertyId: property.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(doc.details.title).font(.headline)
                                Text([doc.details.category.label, doc.details.documentDate.map(ScheduleFormat.longDay) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary).font(.subheadline)
                            }
                        }.accessibilityIdentifier("documents.item.\(doc.id)")
                    }
                }
            } else if failed { Button("Reload documents") { retry += 1 } } else { ProgressView("Loading documents…") }
        }
        .navigationTitle("Documents").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Title, type or confirmed detail")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu { Picker("Document type", selection: $category) { Text("All types").tag(HomeDocumentCategory?.none); ForEach(HomeDocumentCategory.allCases, id: \.self) { Text($0.label).tag(Optional($0)) } } } label: { Label(category?.label ?? "Filter documents", systemImage: category == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                Menu {
                    importButton
                    if VNDocumentCameraViewController.isSupported { Button { scanning = true } label: { Label("Scan pages", systemImage: "document.viewfinder") } }
                } label: { Label("Add document", systemImage: "plus") }.disabled(preparing).accessibilityIdentifier("documents.add")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image]) { result in
            do { let url = try result.get(); Task { await read(url) } } catch let e as CocoaError where e.code == .userCancelled {} catch { problem = error.localizedDescription }
        }
        .sheet(isPresented: $scanning) { DocumentCameraView(onFinish: { pages in
            scanning = false
            do { source = try DocumentSource.scan(pages) } catch { problem = error.localizedDescription }
        }, onCancel: { scanning = false }) }
        .sheet(item: $source) { file in NavigationStack { DocumentEditor(propertyId: property.id, source: file, defaultCategory: initialCategory ?? .other, defaultProject: projectId, currency: property.currencyCode) } }
        .alert("Documents", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} } message: { Text(problem ?? "") }
        .task(id: "\(property.id)-\(retry)") {
            failed = false
            for await next in env.attachments.observeDocuments(propertyId: property.id) { documents = next }
            if !Task.isCancelled { failed = true; documents = nil }
        }
    }
    private var importButton: some View { Button { importing = true } label: { Label("Import from Files", systemImage: "folder") }.accessibilityIdentifier("documents.import") }
    @MainActor private func read(_ url: URL) async {
        preparing = true; defer { preparing = false }
        do { source = try await Task.detached { try DocumentSource.receive(url) }.value } catch { problem = error.localizedDescription }
    }
}

struct HomeDocumentDetail: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    let propertyId: UUID
    @State private var doc: HomeDocument?
    @State private var loaded = false
    @State private var editing: HomeDocument?
    @State private var preview: URL?
    @State private var removing = false
    @State private var problem: String?
    @State private var projectName: String?
    var body: some View {
        Form {
            if let doc {
                Section {
                    Button { Task { if let url = await env.attachments.fileURL(for: doc.attachment) { preview = url } else { problem = "The original is unavailable on this iPhone. Check iCloud sync for earlier attachments." } } } label: { Label("Open original", systemImage: "doc.text.magnifyingglass") }.accessibilityIdentifier("documents.preview")
                    LabeledContent("File", value: doc.details.originalFilename ?? "Original filename unrecorded")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(doc.attachment.byteSize), countStyle: .file))
                }
                Section("Details") {
                    LabeledContent("Type", value: doc.details.category.label)
                    if let date = doc.details.documentDate { LabeledContent("Document date", value: ScheduleFormat.longDay(date)) }
                    if let amount = doc.details.quoteAmount { LabeledContent("Quoted price", value: amount.formatted() + " " + amount.currency) }
                    if let projectName { LabeledContent("Linked project", value: projectName) }
                    ForEach(doc.details.confirmedFields.keys.sorted(), id: \.self) { key in LabeledContent(DocumentField(rawValue: key)?.displayName ?? key, value: doc.details.confirmedFields[key] ?? "") }
                }
                Button("Edit details") { editing = doc }.accessibilityIdentifier("documents.edit")
                Button("Delete document", role: .destructive) { removing = true }
            } else if loaded { ContentUnavailableView("Document unavailable", systemImage: "doc") } else { ProgressView() }
        }
        .navigationTitle(doc?.details.title ?? "Document").navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .sheet(item: $editing) { original in NavigationStack { DocumentEditor(propertyId: propertyId, original: original) } }
        .confirmationDialog("Move this document to Recently Deleted?", isPresented: $removing, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) { Task { do { try await env.attachments.delete(id); dismiss() } catch { problem = error.localizedDescription } } }
        } message: { Text("You can restore it from Settings for 30 days. This also removes it from the record where it was attached.") }
        .alert("Document", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} } message: { Text(problem ?? "") }
        .task(id: id) { for await values in env.attachments.observeDocuments(propertyId: propertyId) { doc = values.first { $0.id == id }; loaded = true } }
        .task(id: doc?.linkedProjectId) { projectName = nil; if let pid = doc?.linkedProjectId { projectName = try? await env.projects.project(pid)?.title } }
    }
}
