import SwiftUI
import HomeCore
import HomeCoreTesting

/// Add / edit a cost line item (FR-PRJ-20): label, amount ≥ 0, kind, vendor, date, hours, receipt.
struct LineItemEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let project: Project
    /// nil = new item.
    let existing: CostLineItem?
    /// Prefill from a scanned receipt (values marked "From receipt – check").
    var receipt: ScannedReceipt?

    @State private var label = ""
    @State private var amountText = ""
    @State private var kind: CostLineItem.Kind = .material
    @State private var vendor = ""
    @State private var hasDate = false
    @State private var incurredOn = LocalDate(2026, 1, 1)
    @State private var hoursText = ""
    @State private var scanned: ScannedReceipt?
    @State private var fromReceipt = false
    @State private var saving = false
    @State private var errorText: String?
    @State private var didLoad = false

    private var currency: String { project.currencyCode }
    private var amount: ProjectInput.MoneyResult { ProjectInput.money(amountText, currency: currency) }
    private var canSave: Bool {
        guard !saving, !label.trimmingCharacters(in: .whitespaces).isEmpty, ProjectInput.hours(hoursText) != nil else { return false }
        if case .value = amount { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label, e.g. LVP planks", text: $label)
                    ProjectMoneyField(title: "Amount", text: $amountText, currency: currency, fromReceipt: fromReceipt)
                    Picker("Kind", selection: $kind) {
                        ForEach(CostLineItem.Kind.knownCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    TextField("Vendor", text: $vendor)
                    Toggle("Date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Date", selection: $incurredOn.scheduleDate(env.clock.calendar), in: ...Date(), displayedComponents: .date)
                    }
                    ProjectHoursField(title: "Hours", text: $hoursText)
                }
                Section("Receipt") {
                    if let scanned {
                        Label("\(scanned.pageCount)-page receipt attached", systemImage: "doc.fill")
                        Button("Remove", role: .destructive) { self.scanned = nil; fromReceipt = false }
                    } else if existing?.receiptAttachmentId != nil {
                        Label("Receipt attached", systemImage: "doc.fill")
                    } else {
                        ReceiptScanButton { r in apply(r) }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Line Item" : "Edit Line Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(!canSave) }
            }
            .alert("Couldn’t save", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        incurredOn = env.clock.today
        if let e = existing {
            label = e.label; amountText = ProjectInput.text(e.amount); kind = e.kind == .unknown ? .other : e.kind
            vendor = e.vendor ?? ""; hasDate = e.incurredOn != nil; incurredOn = e.incurredOn ?? incurredOn
            hoursText = ProjectInput.text(e.hours)
        }
        if let receipt { apply(receipt) }
    }

    private func apply(_ r: ScannedReceipt) {
        scanned = r
        guard let g = r.guess else { return }
        if let total = g.total { amountText = ProjectInput.text(total); fromReceipt = true }
        if let d = g.date { incurredOn = d; hasDate = true }
        if let v = g.vendor, vendor.isEmpty { vendor = v }
        if label.isEmpty, let v = g.vendor { label = v }
    }

    @MainActor
    private func save() async {
        guard canSave, case .value(let money) = amount else { return }
        saving = true
        defer { saving = false }
        let now = env.clock.now
        let vendorValue = vendor.trimmingCharacters(in: .whitespaces)
        var item = existing ?? CostLineItem(propertyId: project.propertyId, projectId: project.id, label: "", amount: money,
                                            createdAt: now, updatedAt: now)
        item.label = label.trimmingCharacters(in: .whitespaces)
        item.amount = money
        item.kind = kind
        item.vendor = vendorValue.isEmpty ? nil : vendorValue
        item.incurredOn = hasDate ? incurredOn : nil
        item.hours = ProjectInput.hours(hoursText) ?? nil
        do {
            if let scanned {
                let att = try await env.attachments.add(scanned.attachmentDraft, ownerType: .costLineItem, ownerId: item.id,
                                                        property: project.propertyId)
                item.receiptAttachmentId = att.id
            }
            try await env.projects.upsertLineItem(item)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

#Preview {
    LineItemEditor(project: Project(propertyId: SampleHome.propertyId, scope: .property, title: "Deck"), existing: nil)
        .environment(AppEnvironment.preview())
}
