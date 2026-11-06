import SwiftUI
import QuickLook
import PDFKit
import HomeCore
import HomeCapture

struct DocumentEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let propertyId: UUID
    let source: DocumentSource?
    let original: HomeDocument?
    let onSaved: () -> Void
    @State private var metadata: HomeDocumentDetails
    @State private var projects: [Project] = []
    @State private var selectedDate: Date
    @State private var hasDate: Bool
    @State private var preview: URL?
    @State private var pagePreview: SuggestedPage?
    @State private var file: URL?
    @State private var reading = false
    @State private var report: DocumentReading?
    @State private var quotedText: String
    @State private var quoteCurrency: String
    @State private var readMessage: String?
    @State private var saving = false
    @State private var problem: String?

    init(propertyId: UUID, source: DocumentSource? = nil, original: HomeDocument? = nil, defaultCategory: HomeDocumentCategory = .other, defaultProject: UUID? = nil, currency: String = "USD", onSaved: @escaping () -> Void = {}) {
        self.propertyId = propertyId; self.source = source; self.original = original; self.onSaved = onSaved
        let initial = original?.details ?? HomeDocumentDetails(title: String(((source?.filename ?? "Document") as NSString).deletingPathExtension.prefix(240)), originalFilename: source?.filename, category: defaultCategory, projectId: defaultProject)
        _quotedText = State(initialValue: initial.quoteAmount?.decimal.formatted(.number.grouping(.never)) ?? "")
        _quoteCurrency = State(initialValue: initial.quoteAmount?.currency ?? currency)
        _metadata = State(initialValue: initial); _file = State(initialValue: source?.url)
        _hasDate = State(initialValue: initial.documentDate != nil)
        var c = Calendar(identifier: .gregorian); c.timeZone = .current
        _selectedDate = State(initialValue: initial.documentDate?.date(atMinutes: 720, calendar: c) ?? Date())
    }
    var body: some View {
        Form {
            Section {
                if let file { Button { preview = file } label: { Label("Review original", systemImage: "doc.text.magnifyingglass") } }
                if let filename = metadata.originalFilename { LabeledContent("File", value: filename) }
                TextField("Document title", text: $metadata.title).accessibilityIdentifier("documents.title")
                Picker("Document type", selection: $metadata.category) { ForEach(HomeDocumentCategory.allCases, id: \.self) { Text($0.label).tag($0) } }
                if metadata.category == .estimate {
                    TextField("Contractor or company", text: Binding(get: { metadata.confirmedFields["contractor"] ?? "" }, set: { metadata.confirmedFields["contractor"] = $0 }))
                    TextField("Quoted amount (optional)", text: $quotedText).keyboardType(.decimalPad).accessibilityIdentifier("documents.quoteAmount")
                    TextField("Currency code", text: $quoteCurrency).textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                Toggle("Document date", isOn: $hasDate)
                if hasDate { DatePicker("Date", selection: $selectedDate, displayedComponents: .date) }
                if original == nil || original?.attachment.ownerType == .property {
                    Picker("Link to project", selection: $metadata.projectId) {
                        Text("Whole home").tag(UUID?.none)
                        ForEach(projects) { Text($0.title).tag(Optional($0.id)) }
                    }
                } else if let linked = original?.linkedProjectId, let project = projects.first(where: { $0.id == linked }) { LabeledContent("Filed on", value: project.title) }
            } footer: { Text(source != nil ? "New library originals and confirmed details stay on this device. To keep another copy, choose Include documents, photos and receipts in Settings → Export data." : "Changing these details preserves the original file.") }
            Section {
                ForEach(metadata.confirmedFields.keys.sorted(), id: \.self) { key in
                    if !(metadata.category == .estimate && key == "contractor") { VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(DocumentField(rawValue: key)?.displayName ?? key).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { metadata.confirmedFields.removeValue(forKey: key) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove \(DocumentField(rawValue: key)?.displayName ?? key)")
                        }
                        TextField("Value", text: Binding(get: { metadata.confirmedFields[key] ?? "" }, set: { metadata.confirmedFields[key] = $0 }), axis: .vertical)
                    } }
                }
                Menu {
                    ForEach(DocumentField.allCases.filter { $0 != .title && $0 != .category && metadata.confirmedFields[$0.rawValue] == nil }, id: \.self) { field in
                        Button(field.displayName) { metadata.confirmedFields[field.rawValue] = "" }
                    }
                } label: { Label("Add detail", systemImage: "plus") }
            } header: { Text("Details you want to keep") }
            if let file {
                Section {
                    if reading { ProgressView("Reading on this device…") }
                    else { Button { Task { await read(file) } } label: { Label(report == nil ? "Look for details on this device" : "Read again", systemImage: "text.viewfinder") }.accessibilityIdentifier("documents.read") }
                    if let readMessage { Text(readMessage).font(.footnote).foregroundStyle(.secondary) }
                    if let report {
                        ForEach(report.candidates) { candidate in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(candidate.field.displayName) · Page \(candidate.page)").font(.caption).foregroundStyle(.secondary)
                                Text(candidate.value).font(.headline)
                                Text(candidate.excerpt).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                                HStack {
                                    Button("Use this detail") { use(candidate) }.buttonStyle(.bordered).accessibilityLabel("Use \(candidate.field.displayName), \(candidate.value)").accessibilityIdentifier("documents.use." + candidate.field.rawValue)
                                    Button("View original") {
                                        if file.pathExtension.lowercased() == "pdf" { pagePreview = SuggestedPage(file: file, page: candidate.page) }
                                        else { preview = file }
                                    }.buttonStyle(.borderless).accessibilityLabel("View original page \(candidate.page)").accessibilityIdentifier("documents.page." + candidate.field.rawValue)
                                }
                            }.padding(.vertical, 3)
                        }
                    }
                } header: { Text("Suggestions") } footer: { Text("Choose the details you recognize, check them against the original and tap Save. You can file a document without reading it.") }
            }
        }
        .disabled(saving).interactiveDismissDisabled(saving)
        .navigationTitle(original == nil ? "File document" : "Edit document").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving || metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("documents.save") }
        }
        .quickLookPreview($preview)
        .sheet(item: $pagePreview) { request in
            NavigationStack {
                SuggestedPageView(request: request)
                    .navigationTitle("Original · Page \(request.page)").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { pagePreview = nil } } }
            }
        }
        .alert("Document", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") {} } message: { Text(problem ?? "") }
        .task(id: propertyId) { for await values in env.projects.observeProjects(.init(propertyId: propertyId)) { projects = values } }
        .task { if let original { file = await env.attachments.fileURL(for: original.attachment); if original.details.quoteAmount == nil, let home = try? await env.plan.currentProperty(), home.id == propertyId { quoteCurrency = home.currencyCode } } }
    }
    @MainActor private func read(_ file: URL) async {
        guard !reading else { return }; reading = true; defer { reading = false }
        do {
            let result = try await HomeDocumentReader().read(file: file); report = result
            if result.candidates.isEmpty { readMessage = "No details were recognized. You can type them above or save the original." }
            else if result.truncated || !result.unreadablePages.isEmpty { readMessage = "Read \(result.pagesRead) of \(result.totalPages) pages. Check the original for additional details." }
            else { readMessage = nil }
        } catch { report = nil; readMessage = "The original can still be saved. \(error.localizedDescription)" }
    }
    private func use(_ candidate: DocumentCandidate) {
        switch candidate.field {
        case .category: if let category = HomeDocumentCategory(rawValue: candidate.value.lowercased()) { metadata.category = category }
        case .title: metadata.title = String(candidate.value.prefix(240))
        case .estimateTotal:
            metadata.category = .estimate
            metadata.confirmedFields[candidate.field.rawValue] = candidate.value
            // Keep ambiguous printed formats for review. Prefill only an unambiguous English-style number.
            let pattern = #"^\s*(?:[A-Z]{3}\s*)?[$€£]?\s*([0-9]{1,3}(?:,[0-9]{3})+|[0-9]{1,12})(?:\.([0-9]{2}))?\s*(?:[A-Z]{3})?\s*$"#
            let raw = candidate.value as NSString
            if let regex = try? NSRegularExpression(pattern: pattern), let hit = regex.firstMatch(in: candidate.value, range: NSRange(location: 0, length: raw.length)) {
                let whole = raw.substring(with: hit.range(at: 1)).replacingOccurrences(of: ",", with: "")
                quotedText = whole + (hit.range(at: 2).location == NSNotFound ? "" : (Locale.current.decimalSeparator ?? ".") + raw.substring(with: hit.range(at: 2)))
                if let code = candidate.value.range(of: #"\b[A-Z]{3}\b"#, options: .regularExpression) { quoteCurrency = String(candidate.value[code]) }
                else if candidate.value.contains("€") { quoteCurrency = "EUR" }
                else if candidate.value.contains("£") { quoteCurrency = "GBP" }
            }
        default: metadata.confirmedFields[candidate.field.rawValue] = String(candidate.value.prefix(2048))
        }
    }
    @MainActor private func save() async {
        guard !saving else { return }; saving = true; defer { saving = false }
        do {
            var details = metadata
            details.title = details.title.trimmingCharacters(in: .whitespacesAndNewlines)
            details.quoteAmount = nil
            if details.category == .estimate, !quotedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let digits = quotedText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
                guard digits.range(of: #"^[0-9]{1,12}(\.[0-9]{1,2})?$"#, options: .regularExpression) != nil, let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { throw HomeDocumentError("Enter a quoted amount with up to two decimal places, without a currency symbol.") }
                details.quoteAmount = Money(major: value, currency: quoteCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            }
            details.documentDate = hasDate ? LocalDate(selectedDate, calendar: env.clock.calendar) : nil
            details.confirmedFields = details.confirmedFields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let original { try await env.attachments.updateDocument(original, details: details) }
            else if let source {
                let kind: Attachment.Kind = details.category == .receipt ? .receipt : (details.category == .manual ? .manual : .document)
                _ = try await env.attachments.fileDocument(.init(fileURL: source.url, kind: kind, uti: source.type.identifier), propertyId: propertyId, details: details)
            } else { throw HomeDocumentError("Choose a file first.") }
            onSaved(); dismiss()
        } catch { problem = error.localizedDescription }
    }
}

private struct SuggestedPage: Identifiable {
    let id = UUID()
    let file: URL
    let page: Int
}

private struct SuggestedPageView: UIViewRepresentable {
    let request: SuggestedPage
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayDirection = .vertical
        if let document = PDFDocument(url: request.file) {
            view.document = document
            if request.page > 0, request.page <= document.pageCount, let target = document.page(at: request.page - 1) { view.go(to: target) }
        }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
}
