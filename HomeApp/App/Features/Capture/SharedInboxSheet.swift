import SwiftUI
import HomeCore
import HomeCoreTesting
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Something shared into Home Blueprint from Mail, Photos, Files or any app (via the share extension) that isn't a
/// to-do list: a receipt, a document, or a note such as a contractor's reply. Its files are written to the temporary
/// directory so the attachment store can copy them.
struct SharedInboxItem: Identifiable {
    struct LocalFile: Identifiable {
        var file: SharedInbox.File
        var url: URL
        var id: UUID { file.id }
    }

    let id = UUID()
    var kind: SharedInbox.Kind
    var text: String
    var files: [LocalFile]
    var createdAt: Date

    /// From the keychain hand-off. nil when nothing usable came through (no text and no readable files).
    static func make(from taken: SharedCaptureInbox.Taken) -> SharedInboxItem? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SharedInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [LocalFile] = []
        for p in taken.payloads {
            let url = dir.appendingPathComponent("\(p.file.id.uuidString.lowercased()).\(p.file.fileExt)")
            if (try? p.data.write(to: url, options: .atomic)) != nil { files.append(LocalFile(file: p.file, url: url)) }
        }
        let text = taken.entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !files.isEmpty || !text.isEmpty else { return nil }
        let kind: SharedInbox.Kind = taken.entry.kind == .todos ? (files.isEmpty ? .note : .receipt) : taken.entry.kind
        return SharedInboxItem(kind: kind, text: text, files: files, createdAt: taken.entry.createdAt)
    }

    /// Removes the temporary copies (the attachment store has its own).
    func cleanUp() {
        for f in files { try? FileManager.default.removeItem(at: f.url) }
    }
}

/// "File it": where a shared receipt, document or note goes. Shows what came in; for receipts reads the store, total
/// and date (`ReceiptReading`; a PDF's first page is rendered for it) for checking; then files it on an existing
/// project (attachment, and optionally a cost line item), an item (attachment, purchase price), or a new project.
/// Text is added to the project's or item's notes under a date header. Self-contained (own `NavigationStack`).
struct SharedInboxSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    enum Destination: Hashable { case project, thing, newProject }

    let item: SharedInboxItem

    @State private var kind: SharedInbox.Kind
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var propertyId: UUID?
    @State private var currency = "USD"
    @State private var projects: [Project] = []
    @State private var things: [Thing] = []
    @State private var destination: Destination = .newProject
    @State private var projectId: UUID?
    @State private var thingId: UUID?
    @State private var newTitle = ""
    // Receipt details (prefilled from the receipt, editable).
    @State private var vendor = ""
    @State private var amountText = ""
    @State private var hasDate = false
    @State private var date = LocalDate(2026, 1, 1)
    @State private var guess: ReceiptGuess?
    @State private var reading = false
    @State private var didRead = false
    @State private var readFailed = false
    @State private var addCost = true
    @State private var setPurchase = true
    @State private var loaded = false
    @State private var saving = false
    @State private var errorText: String?

    init(item: SharedInboxItem) {
        self.item = item
        _kind = State(initialValue: item.kind == .todos ? .note : item.kind)
    }

    private var hasText: Bool { !item.text.isEmpty }
    private var amount: Money? {
        if case .value(let m) = ProjectInput.money(amountText, currency: currency) { return m }
        return nil
    }
    private var amountInvalid: Bool {
        if case .invalid = ProjectInput.money(amountText, currency: currency) { return true }
        return false
    }
    private var selectedProject: Project? { projects.first { $0.id == projectId } }
    private var selectedThing: Thing? { things.first { $0.id == thingId } }
    private var canSave: Bool {
        guard loaded, !saving, propertyId != nil, !amountInvalid else { return false }
        switch destination {
        case .project: return selectedProject != nil
        case .thing: return selectedThing != nil
        case .newProject: return !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                receivedSection
                Section {
                    Picker("This is", selection: $kind) {
                        Text("Receipt").tag(SharedInbox.Kind.receipt)
                        Text("Document").tag(SharedInbox.Kind.document)
                        Text("Note").tag(SharedInbox.Kind.note)
                    }
                    .pickerStyle(.segmented)
                }
                if kind == .receipt { receiptSection }
                destinationSection
            }
            .navigationTitle("File it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Discard") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .bold()
                        .disabled(!canSave)
                }
            }
            .alert("Couldn’t save", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
        .feedbackPage("File it")
        .interactiveDismissDisabled(saving)
        .task { await load() }
        .onChange(of: kind) { _, k in if k == .receipt { Task { await readReceipt() } } }
        .onDisappear { item.cleanUp() }
    }

    // MARK: Sections

    private var receivedSection: some View {
        Section {
            ForEach(item.files) { f in
                HStack(spacing: 12) {
                    preview(f)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.file.name).lineLimit(2)
                        Text(SharedInbox.sizeText(f.file.byteSize)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if hasText {
                Text(item.text).font(.callout).lineLimit(10)
            }
        } header: {
            Text("Shared \(ScheduleFormat.longDay(LocalDate(item.createdAt, calendar: env.clock.calendar)))")
        }
    }

    @ViewBuilder
    private func preview(_ f: SharedInboxItem.LocalFile) -> some View {
        if let image = thumbnails[f.id] {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.quaternary))
        } else {
            Image(systemName: f.file.isPDF ? "doc.richtext" : "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
        }
    }

    private var receiptSection: some View {
        Section {
            if reading {
                HStack { ProgressView(); Text("Reading the receipt…").foregroundStyle(.secondary) }
            }
            TextField("Store or company", text: $vendor)
            ProjectMoneyField(title: "Total", text: $amountText, currency: currency, fromReceipt: guess?.total != nil)
            Toggle("Date", isOn: $hasDate)
            if hasDate {
                DatePicker("Date", selection: $date.scheduleDate(env.clock.calendar), in: ...Date(), displayedComponents: .date)
            }
        } header: {
            Text("From the receipt")
        } footer: {
            if readFailed {
                Text("Couldn’t read this receipt. You can still file it and type the amount.")
            } else if guess != nil {
                Text("Read from the receipt — check before saving.")
            } else if item.files.isEmpty {
                Text("Type the total to add it as a cost.")
            }
        }
    }

    private var destinationSection: some View {
        Section {
            Picker("File it in", selection: $destination) {
                if !projects.isEmpty { Text("A project").tag(Destination.project) }
                if !things.isEmpty { Text("An item").tag(Destination.thing) }
                Text("New project").tag(Destination.newProject)
            }
            switch destination {
            case .project:
                Picker("Project", selection: $projectId) {
                    ForEach(projects) { p in Text(p.title).tag(UUID?.some(p.id)) }
                }
                costToggle
            case .thing:
                Picker("Item", selection: $thingId) {
                    ForEach(things) { t in Text(t.name).tag(UUID?.some(t.id)) }
                }
                if kind == .receipt, let amount, let thing = selectedThing, thing.purchasePrice == nil {
                    Toggle("Save \(amount.formatted()) as its purchase price", isOn: $setPurchase)
                }
            case .newProject:
                TextField("Project name", text: $newTitle)
                costToggle
            }
        } header: {
            Text("Where it goes")
        } footer: {
            Text(destinationFooter)
        }
    }

    @ViewBuilder
    private var costToggle: some View {
        if kind == .receipt, let amount {
            Toggle("Add \(amount.formatted()) as a cost", isOn: $addCost)
        }
    }

    private var destinationFooter: String {
        var parts: [String] = []
        if !item.files.isEmpty {
            switch kind {
            case .receipt: parts.append(item.files.count == 1 ? "The receipt is kept with it." : "The receipts are kept with it.")
            default: parts.append(item.files.count == 1 ? "The file is kept with it." : "The files are kept with it.")
            }
        }
        if hasText { parts.append("The text is added to its notes.") }
        if destination == .project, kind == .receipt, addCost, amount != nil, selectedProject?.actualCost != nil {
            parts.append("This project has an actual cost typed in, which is shown instead of its costs added up.")
        }
        if destination == .newProject { parts.append(kind == .receipt ? "The project starts as In progress." : "The project starts as an idea.") }
        return parts.joined(separator: " ")
    }

    // MARK: Loading

    @MainActor
    private func load() async {
        guard !loaded else { return }
        date = env.clock.today
        thumbnails = await Self.makeThumbnails(item.files)
        if let p = try? await env.plan.currentProperty() {
            propertyId = p.id
            currency = p.currencyCode
            let all = ((try? await env.projects.projects(ProjectQuery(propertyId: p.id))) ?? []).filter { $0.deletedAt == nil }
            projects = all.sorted { (Self.order($0.status), $1.updatedAt) < (Self.order($1.status), $0.updatedAt) }
            things = ((try? await env.things.things(ThingQuery(propertyId: p.id))) ?? [])
                .filter { $0.deletedAt == nil }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        projectId = projects.first?.id
        thingId = things.first?.id
        destination = projects.isEmpty ? .newProject : .project
        newTitle = SharedInbox.suggestedTitle(vendor: nil, text: item.text, kind: kind)
        loaded = true
        if kind == .receipt { await readReceipt() }
    }

    /// In progress first, then planned, ideas and finished work; most recently touched first within each.
    private static func order(_ s: Project.Status) -> Int {
        switch s {
        case .inProgress: return 0
        case .planned: return 1
        case .idea: return 2
        case .done: return 3
        case .unknown: return 4
        }
    }

    /// OCR once: photos as they are, a PDF's first page rendered to an image.
    @MainActor
    private func readReceipt() async {
        guard !didRead, !item.files.isEmpty else { return }
        didRead = true
        reading = true
        defer { reading = false }
        let images = await Self.receiptImages(item.files)
        guard !images.isEmpty else { readFailed = true; return }
        do {
            let g = try await env.receipts.read(images: images)
            guess = g
            if let total = g.total, amountText.isEmpty { amountText = ProjectInput.text(total) }
            if let d = g.date { date = d; hasDate = true }
            if let v = g.vendor?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                if vendor.isEmpty { vendor = v }
                let defaultTitle = SharedInbox.suggestedTitle(vendor: nil, text: item.text, kind: kind)
                if newTitle.isEmpty || newTitle == defaultTitle { newTitle = v }
            }
        } catch {
            readFailed = true
        }
    }

    private static func makeThumbnails(_ files: [SharedInboxItem.LocalFile]) async -> [UUID: UIImage] {
        var out: [UUID: UIImage] = [:]
        for f in files {
            if f.file.isPDF {
                #if canImport(PDFKit)
                if let page = PDFDocument(url: f.url)?.page(at: 0) {
                    out[f.id] = page.thumbnail(of: CGSize(width: 160, height: 160), for: .mediaBox)
                }
                #endif
            } else if let image = UIImage(contentsOfFile: f.url.path) {
                out[f.id] = image.preparingThumbnail(of: CGSize(width: 160, height: 160 * image.size.height / max(1, image.size.width)))
            }
        }
        return out
    }

    /// JPEG data for OCR: up to three photos, or the first page of the first PDF.
    private static func receiptImages(_ files: [SharedInboxItem.LocalFile]) async -> [Data] {
        let photos = files.filter { $0.file.isImage }.prefix(3).compactMap { try? Data(contentsOf: $0.url) }
        if !photos.isEmpty { return Array(photos) }
        #if canImport(PDFKit)
        if let pdf = files.first(where: { $0.file.isPDF }), let page = PDFDocument(url: pdf.url)?.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let longEdge = max(bounds.width, bounds.height)
            guard longEdge > 0 else { return [] }
            let scale = min(4, 2000 / longEdge)
            let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
            if let data = image.jpegData(compressionQuality: 0.85) { return [data] }
        }
        #endif
        return []
    }

    // MARK: Saving

    @MainActor
    private func save() async {
        guard canSave, let propertyId else { return }
        saving = true
        defer { saving = false }
        do {
            switch destination {
            case .project:
                guard let project = selectedProject else { return }
                try await file(on: project, isNew: false)
            case .thing:
                guard let thing = selectedThing else { return }
                try await file(on: thing, property: propertyId)
            case .newProject:
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let vendorValue = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
                let draft = ProjectDraft(propertyId: propertyId, scope: .property, title: title,
                                         notes: hasText ? SharedInbox.appendingNote(item.text, to: nil, header: noteHeader) : nil,
                                         status: kind == .receipt ? .inProgress : .idea,
                                         vendor: kind == .receipt && !vendorValue.isEmpty ? vendorValue : nil)
                let project = try await env.projects.create(draft)
                try await file(on: project, isNew: true)
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// "Receipt shared Oct 5, 2026".
    private var noteHeader: String {
        let day = ScheduleFormat.longDay(LocalDate(item.createdAt, calendar: env.clock.calendar))
        switch kind {
        case .receipt: return "Receipt shared \(day)"
        case .document: return "Document shared \(day)"
        case .note, .todos: return "Shared \(day)"
        }
    }

    @MainActor
    private func file(on project: Project, isNew: Bool) async throws {
        if !isNew && hasText {
            var p = project
            p.notes = SharedInbox.appendingNote(item.text, to: p.notes, header: noteHeader)
            try await env.projects.update(p)
        }
        var drafts = try attachmentDrafts()
        if kind == .receipt, addCost, let amount {
            let vendorValue = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
            let now = env.clock.now
            var line = CostLineItem(propertyId: project.propertyId, projectId: project.id,
                                    label: vendorValue.isEmpty ? "Receipt" : vendorValue, amount: amount, kind: .other,
                                    vendor: vendorValue.isEmpty ? nil : vendorValue, incurredOn: hasDate ? date : nil,
                                    createdAt: now, updatedAt: now)
            if !drafts.isEmpty {
                let receipt = drafts.removeFirst()
                let att = try await env.attachments.add(receipt, ownerType: .costLineItem, ownerId: line.id,
                                                        property: project.propertyId)
                line.receiptAttachmentId = att.id
            }
            try await env.projects.upsertLineItem(line)
        }
        for d in drafts {
            _ = try await env.attachments.add(d, ownerType: .project, ownerId: project.id, property: project.propertyId)
        }
    }

    @MainActor
    private func file(on thing: Thing, property: UUID) async throws {
        for d in try attachmentDrafts() {
            _ = try await env.attachments.add(d, ownerType: .thing, ownerId: thing.id, property: property)
        }
        var t = thing
        var changed = false
        if hasText {
            t.notes = SharedInbox.appendingNote(item.text, to: t.notes, header: noteHeader)
            changed = true
        }
        if kind == .receipt, setPurchase, let amount, t.purchasePrice == nil {
            t.purchasePrice = amount
            if hasDate && t.purchaseDate == nil { t.purchaseDate = date }
            changed = true
        }
        if changed { try await env.things.update(t) }
    }

    /// Receipts: photos combined into one PDF (like a scan) plus any PDFs. Documents and notes: each file as-is.
    private func attachmentDrafts() throws -> [AttachmentDraft] {
        let now = env.clock.now
        let vendorValue = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocr = guess?.fullText.isEmpty == false ? guess?.fullText : nil
        var drafts: [AttachmentDraft] = []
        if kind == .receipt {
            let photos = item.files.filter { $0.file.isImage }
            if !photos.isEmpty {
                let datas = photos.compactMap { try? Data(contentsOf: $0.url) }
                guard let pdf = ReceiptPDF.write(images: datas) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn’t save the receipt photos. Try again."])
                }
                drafts.append(AttachmentDraft(fileURL: pdf, kind: .receipt, fileExt: "pdf", uti: "com.adobe.pdf",
                                              caption: vendorValue.isEmpty ? nil : vendorValue, ocrText: ocr, capturedAt: now))
            }
            for f in item.files where f.file.isPDF {
                drafts.append(AttachmentDraft(fileURL: f.url, kind: .receipt, fileExt: "pdf", uti: f.file.uti,
                                              caption: vendorValue.isEmpty ? Self.baseName(f.file.name) : vendorValue,
                                              ocrText: drafts.isEmpty ? ocr : nil, capturedAt: now))
            }
        } else {
            for f in item.files {
                drafts.append(AttachmentDraft(fileURL: f.url, kind: .document, fileExt: f.file.fileExt, uti: f.file.uti,
                                              caption: Self.baseName(f.file.name), capturedAt: now))
            }
        }
        return drafts
    }

    private static func baseName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }
}

// MARK: - Demo

extension SharedInboxItem {
    /// A receipt photo as if shared from Mail, for the `shared-receipt` screenshot. Matches the in-memory receipt
    /// reader's answer (Hardware Store, $4,612.00).
    static let demoReceipt: SharedInboxItem = {
        var files: [LocalFile] = []
        #if canImport(UIKit)
        let size = CGSize(width: 600, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let lines: [(String, CGFloat, UIFont.Weight)] = [
                ("HARDWARE STORE", 34, .bold), ("123 Main St · Springfield", 20, .regular), ("", 20, .regular),
                ("Composite deck boards ×40      3,960.00", 22, .regular), ("Hidden fasteners ×6              312.00", 22, .regular),
                ("Deck screws ×4                      96.00", 22, .regular), ("", 20, .regular),
                ("SUBTOTAL                        4,368.00", 22, .regular), ("TAX                                  244.00", 22, .regular),
                ("TOTAL                           4,612.00", 28, .bold), ("", 20, .regular), ("Thank you!", 22, .regular),
            ]
            var y: CGFloat = 50
            for (text, fontSize, weight) in lines {
                let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
                (text as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: [.font: font, .foregroundColor: UIColor.black])
                y += fontSize * 1.6
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-receipt.jpg")
        if let data = image.jpegData(compressionQuality: 0.7), (try? data.write(to: url)) != nil {
            files.append(LocalFile(file: SharedInbox.File(name: "Receipt.jpg", uti: "public.jpeg", fileExt: "jpg", byteSize: data.count),
                                   url: url))
        }
        #endif
        return SharedInboxItem(kind: .receipt, text: "", files: files, createdAt: Date())
    }()
}

#Preview("File it · receipt") {
    SharedInboxSheet(item: SharedInboxItem.demoReceipt).environment(AppEnvironment.preview())
}

#Preview("File it · contractor reply") {
    SharedInboxSheet(item: SharedInboxItem(kind: .note,
                                           text: "Hi! We can start the deck on Monday the 12th. Materials are on order.\n— Sam, Oak & Nail Builders",
                                           files: [], createdAt: Date()))
        .environment(AppEnvironment.preview())
}
