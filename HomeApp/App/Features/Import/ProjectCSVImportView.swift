import SwiftUI
import UniformTypeIdentifiers
import HomeCore

struct ProjectCSVFile: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let data: Data
    static let maxBytes = ProjectCSV.maxBytes

    static func read(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard info.isDirectory != true, (info.fileSize ?? 0) <= maxBytes else { throw ProjectCSVError("Choose a spreadsheet text file of 4 MB or less.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maxBytes + 1 - bytes.count)), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= maxBytes else { throw ProjectCSVError("Choose a file of 4 MB or less.") }
        }
        return Self(name: url.lastPathComponent, data: bytes)
    }
}

private struct SpreadsheetColumnPicker: View {
    @Environment(\.dismiss) private var dismiss
    let headers: [String]
    let field: ProjectCSVField
    let selected: Int?
    let select: (Int?) -> Void

    var selectedTitle: String { title(selected) }

    private func title(_ index: Int?) -> String {
        guard let index, headers.indices.contains(index) else {
            return field == .title ? "Choose column" : "Skip"
        }
        return "\(index + 1). " + (headers[index].isEmpty ? "Unnamed column" : headers[index])
    }

    var body: some View {
        List {
            choice(nil)
            ForEach(headers.indices, id: \.self) { choice($0) }
        }
        .navigationTitle(field.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choice(_ index: Int?) -> some View {
        Button {
            select(index)
            dismiss()
        } label: {
            HStack {
                Text(title(index))
                Spacer()
                if index == selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(index == selected ? .isSelected : [])
        .accessibilityIdentifier(index.map { "csv.columnChoice.\($0)" } ?? "csv.columnChoice.none")
    }
}

private struct SampleProjectsCSV: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    let bytes: Data
    init(currency: String) {
        bytes = ProjectCSV.sample(currency: currency)
    }
    init(configuration: ReadConfiguration) throws { bytes = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}

struct ProjectCSVImportView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let property: Property
    let initialFile: ProjectCSVFile?
    init(property: Property, initialFile: ProjectCSVFile? = nil) { self.property = property; self.initialFile = initialFile }

    @State private var file: ProjectCSV?
    @State private var fileName = ""
    @State private var mapping: ProjectCSVMapping?
    @State private var mappedRows: [ProjectCSVReview] = []
    @State private var results: [Int: ProjectCSVDisposition] = [:]
    @State private var excluded = Set<Int>()
    @State private var revision = 0
    @State private var loading = false
    @State private var reviewing = false
    @State private var saving = false
    @State private var importing = false
    @State private var exporting = false
    @State private var mappingOpen = false
    @State private var confirming = false
    @State private var error: String?
    @State private var summary: String?

    private var ready: [ProjectCSVItem] { mappedRows.compactMap { results[$0.id] == .ready && !excluded.contains($0.id) ? $0.item : nil } }
    private var duplicates: Int { results.values.filter { $0 == .duplicate }.count }
    private var conflicts: Int { results.values.filter { if case .conflict = $0 { return true }; return false }.count }
    private var busy: Bool { saving || loading }

    var body: some View {
        Form {
            if let summary {
                Section {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(summary)
                        .accessibilityIdentifier("csv.outcome")
                }
                Button("Done") { dismiss() }
            } else {
                Section {
                    Button { importing = true } label: { Label(file == nil ? "Choose spreadsheet file" : "Choose another file", systemImage: "folder") }
                        .disabled(busy).accessibilityIdentifier("csv.choose")
                    if file == nil {
                        Button { exporting = true } label: { Label("Save example CSV", systemImage: "square.and.arrow.down") }
                            .accessibilityIdentifier("csv.sample")
                    }
                    if !fileName.isEmpty { Text(fileName).font(.footnote).foregroundStyle(.secondary) }
                    if loading { ProgressView("Reading spreadsheet…") }
                } header: { Text(property.name) } footer: {
                    Text("In Excel, save the sheet as CSV UTF-8 or Unicode text. Start with a project title. Dates, costs and other details are optional.")
                }
                if let file, mapping != nil {
                    columns(file)
                    if reviewing { ProgressView("Checking rows…") }
                    if !mappedRows.isEmpty && !reviewing {
                        Section {
                            LabeledContent("Ready to import", value: String(ready.count))
                                .accessibilityElement(children: .ignore).accessibilityLabel("Ready to import").accessibilityValue(String(ready.count)).accessibilityIdentifier("csv.readyCount")
                            if duplicates > 0 { LabeledContent("Duplicates", value: String(duplicates)) }
                            let invalid = mappedRows.filter { $0.issue != nil }.count
                            if invalid + conflicts > 0 { LabeledContent("Need attention", value: String(invalid + conflicts)) }
                            if !excluded.isEmpty { LabeledContent("Skipped by you", value: String(excluded.count)) }
                            NavigationLink("Review all \(mappedRows.count) rows") { reviewList }
                                .accessibilityIdentifier("csv.review")
                            if let first = ready.first {
                                VStack(alignment: .leading) { Text("First project").font(.caption).foregroundStyle(.secondary); itemPreview(first) }
                            }
                        } header: { Text("Preview") } footer: {
                            Text("Ready rows become completed projects for the whole home. Duplicates, conflicts and invalid rows are skipped. Rooms, individual expense lines and attachments stay in the source file.")
                        }
                        Button("Import \(ready.count) projects") { confirming = true }
                            .disabled(ready.isEmpty || busy).accessibilityIdentifier("csv.import")
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) } }
            }
        }
        .navigationTitle("Import projects")
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                Task { await choose(url: url) }
            } catch let issue as CocoaError where issue.code == .userCancelled { }
            catch { self.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: SampleProjectsCSV(currency: property.currencyCode),
                      contentType: .commaSeparatedText, defaultFilename: "Home Blueprint project example") { result in
            if case .failure(let issue) = result, (issue as? CocoaError)?.code != .userCancelled { error = issue.localizedDescription }
        }
        .task(id: initialFile?.id) {
            if let initialFile, file == nil, summary == nil { await load(initialFile) }
        }
        .task(id: revision) { await review() }
        .confirmationDialog("Import \(ready.count) completed projects into \(property.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Import projects") { Task { await commit() } }.accessibilityIdentifier("csv.confirm")
            Button("Cancel", role: .cancel) {}
        }
    }

    private func columns(_ file: ProjectCSV) -> some View {
        Section {
            DisclosureGroup("Match columns", isExpanded: $mappingOpen) {
                ForEach(ProjectCSVField.allCases) { field in
                    let picker = SpreadsheetColumnPicker(headers: file.headers, field: field, selected: mapping?.columns[field]) { index in
                        mapping?.columns[field] = index
                        invalidate()
                    }
                    NavigationLink {
                        picker
                    } label: {
                        LabeledContent(field.rawValue, value: picker.selectedTitle)
                    }
                    .accessibilityIdentifier("csv.column." + field.rawValue)
                }
                if mapping?.columns[.date] != nil {
                    Picker("Slash dates", selection: Binding(get: { mapping?.dayFirst ?? false }, set: { mapping?.dayFirst = $0; invalidate() })) {
                        Text("Month / day / year").tag(false); Text("Day / month / year").tag(true)
                    }
                }
                if mapping?.columns[.cost] != nil {
                    Picker("Number format", selection: Binding(get: { mapping?.decimalComma ?? false }, set: { mapping?.decimalComma = $0; invalidate() })) {
                        Text("1,234.56").tag(false); Text("1.234,56").tag(true)
                    }
                }
            }
        } footer: { Text("Costs use this home’s currency (\(property.currencyCode)). A year alone stays a year.") }
    }

    private var reviewList: some View {
        List(mappedRows) { row in
            VStack(alignment: .leading, spacing: 4) {
                Text("Row \(row.id)").font(.caption).foregroundStyle(.secondary)
                if let item = row.item {
                    itemPreview(item)
                    if let disposition = results[row.id] {
                        if disposition == .duplicate { Label("Duplicate · skipped", systemImage: "square.on.square") }
                        if case .conflict(let reason) = disposition { Label(reason, systemImage: "exclamationmark.circle") }
                    }
                    if results[row.id] == .ready || excluded.contains(row.id) {
                        Toggle("Include row", isOn: Binding(get: { !excluded.contains(row.id) }, set: { include in
                            if include { excluded.remove(row.id) } else { excluded.insert(row.id) }
                            invalidate(clearRows: false)
                        }))
                        .disabled(busy)
                        .accessibilityLabel("Include \(item.title)")
                    }
                } else {
                    if !row.title.isEmpty { Text(row.title).font(.headline) }
                    Label(row.issue ?? "Row is incomplete.", systemImage: "exclamationmark.circle")
                }
            }.padding(.vertical, 3)
        }.navigationTitle("Review rows")
    }

    private func itemPreview(_ item: ProjectCSVItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.headline)
            Text([item.day?.description ?? item.year.map(String.init) ?? "Date unknown", item.cost?.formatted() ?? "Cost unknown"].joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
            let detail = [item.vendor, item.action?.displayName, item.notes].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty { Text(detail).font(.footnote) }
        }
    }

    private func invalidate(clearRows: Bool = true) {
        if clearRows { mappedRows.removeAll() }
        results.removeAll()
        error = nil
        reviewing = true
        revision += 1
    }

    @MainActor private func choose(url: URL) async {
        file = nil; fileName = ""; mapping = nil; mappedRows = []; results = [:]; error = nil
        revision += 1
        loading = true
        defer { loading = false }
        do {
            let picked = try await Task.detached { try ProjectCSVFile.read(url) }.value
            await load(picked)
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func load(_ source: ProjectCSVFile) async {
        loading = true
        defer { loading = false }
        do {
            let decoded = try await Task.detached { try ProjectCSV(data: source.data) }.value
            file = decoded; fileName = source.name; excluded = []
            let proposed = ProjectCSVMapping(decoded)
            mapping = proposed; mappingOpen = proposed.columns[.title] == nil
            invalidate()
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func review() async {
        guard let file, let mapping else { return }
        let version = revision
        do {
            let currency = property.currencyCode
            let rows = try await Task.detached { try file.review(mapping: mapping, currency: currency) }.value
            let included = rows.compactMap { excluded.contains($0.id) ? nil : $0.item }
            let decisions = try await env.projects.reviewCSVImport(included, propertyID: property.id)
            guard !Task.isCancelled, revision == version else { return }
            mappedRows = rows
            results = Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0.disposition) })
            error = nil
        } catch {
            guard !Task.isCancelled, revision == version else { return }
            self.error = error.localizedDescription
        }
        reviewing = false
    }

    @MainActor private func commit() async {
        guard !saving, !reviewing, !ready.isEmpty else { return }
        let rows = ready
        saving = true
        defer { saving = false }
        do {
            let outcomes = try await env.projects.importCompletedCSV(rows, propertyID: property.id)
            let added = outcomes.filter { $0.disposition == .ready }.count
            let skipped = mappedRows.count - added
            summary = "Added \(added) completed \(added == 1 ? "project" : "projects") to \(property.name)." + (skipped > 0 ? " Skipped \(skipped) rows." : "")
        } catch { self.error = error.localizedDescription }
    }
}

