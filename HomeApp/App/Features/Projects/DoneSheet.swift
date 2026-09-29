import SwiftUI
import HomeCore
import HomeCoreTesting

/// The Done sheet (FR-PRJ-12, HLD §4.8, AC-PRJ-3/6): final cost, completion date, hours and an optional scanned
/// receipt. Prefilled with the line-item sum (else the estimate), today, and line-item hours (else the estimate).
/// Confirm calls `ProjectRepository.markDone`; the project then leaves Future Projects and shows in Past Work.
struct DoneSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let project: Project
    let lineItems: [CostLineItem]
    var onDone: (() -> Void)?

    @State private var actualText = ""
    @State private var hoursText = ""
    @State private var completedOn = LocalDate(2026, 1, 1)
    @State private var receipt: ScannedReceipt?
    @State private var costFromReceipt = false
    @State private var receiptTotalText: String?
    @State private var dateFromReceipt = false
    @State private var saving = false
    @State private var errorText: String?
    @State private var didLoad = false

    private var currency: String { project.currencyCode }
    private var liveItems: [CostLineItem] { lineItems.filter { $0.deletedAt == nil && $0.projectId == project.id } }
    private var lineSum: Money { Money(cents: liveItems.reduce(0) { $0 + $1.amount.cents }, currency: currency) }
    private var lineHours: Double { liveItems.reduce(0) { $0 + ($1.hours ?? 0) } }

    private var actual: ProjectInput.MoneyResult { ProjectInput.money(actualText, currency: currency) }
    private var canConfirm: Bool {
        if saving { return false }
        if case .invalid = actual { return false }
        return ProjectInput.hours(hoursText) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(project.title).font(.headline)
                } footer: {
                    Text("Marking it done moves it to Past Work. The estimate is kept so you can compare.")
                }

                Section("Final cost") {
                    ProjectMoneyField(title: "Actual cost", text: $actualText, currency: currency, fromReceipt: costFromReceipt)
                        .onChange(of: actualText) { _, new in if new != receiptTotalText { costFromReceipt = false } }
                    if !liveItems.isEmpty {
                        LabeledContent("Line items total", value: lineSum.formatted())
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let est = project.estCost {
                        LabeledContent("Estimate", value: est.formatted())
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("When and how long") {
                    VStack(alignment: .leading, spacing: 2) {
                        DatePicker("Completed", selection: $completedOn.scheduleDate(env.clock.calendar), in: ...Date(),
                                   displayedComponents: .date)
                        if dateFromReceipt {
                            Label("From receipt – check", systemImage: "doc.text.viewfinder").font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    ProjectHoursField(title: "Hours", text: $hoursText)
                }

                Section("Receipt") {
                    if let receipt {
                        HStack {
                            Image(systemName: "doc.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(receipt.guess?.vendor ?? "Receipt")
                                Text([receipt.guess?.date.map { ScheduleFormat.longDay($0) }, receipt.guess?.total?.formatted(),
                                      "\(receipt.pageCount) page\(receipt.pageCount == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { clearReceipt() }.font(.footnote)
                        }
                    } else {
                        ReceiptScanButton { apply($0) }
                    }
                }
            }
            .navigationTitle("Mark Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Confirm") { Task { await confirm() } }.disabled(!canConfirm) }
            }
            .alert("Couldn’t mark done", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard !didLoad else { return }
        didLoad = true
        completedOn = env.clock.today
        if let a = project.actualCost { actualText = ProjectInput.text(a) }
        else if !liveItems.isEmpty { actualText = ProjectInput.text(lineSum) }
        else if let est = project.estCost { actualText = ProjectInput.text(est) }
        if let h = project.actualHours { hoursText = ProjectInput.text(h) }
        else if lineHours > 0 { hoursText = ProjectInput.text(lineHours) }
        else { hoursText = ProjectInput.text(project.estHours) }
    }

    private func apply(_ r: ScannedReceipt) {
        receipt = r
        guard let g = r.guess else { return }
        if let total = g.total {
            let text = ProjectInput.text(total)
            receiptTotalText = text
            actualText = text
            costFromReceipt = true
        }
        if let d = g.date, d <= env.clock.today { completedOn = d; dateFromReceipt = true }
    }

    private func clearReceipt() {
        receipt = nil
        receiptTotalText = nil
        costFromReceipt = false
        dateFromReceipt = false
    }

    @MainActor
    private func confirm() async {
        guard canConfirm else { return }
        saving = true
        defer { saving = false }
        let money: Money? = { if case .value(let m) = actual { return m }; return nil }()
        // Keep "actual" empty when it equals the line-item sum so line items keep driving the total (§8.1).
        let entered: Money? = (money != nil && !liveItems.isEmpty && money == lineSum && project.actualCost == nil) ? nil : money
        do {
            try await env.projects.markDone(project.id, actual: entered, completedOn: completedOn,
                                            hours: ProjectInput.hours(hoursText) ?? nil, receipt: receipt?.attachmentDraft)
            onDone?()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private enum DoneSheetPreviewData {
    static let project = Project(propertyId: SampleHome.propertyId, scope: .property, title: "Replace fridge", status: .inProgress,
                                 estCost: Money(cents: 2_400_00), estHours: 4)
    static let items = [CostLineItem(propertyId: SampleHome.propertyId, projectId: project.id, label: "Fridge",
                                     amount: Money(cents: 2_199_00), incurredOn: LocalDate(2026, 9, 20))]
}

#Preview {
    DoneSheet(project: DoneSheetPreviewData.project, lineItems: DoneSheetPreviewData.items)
        .environment(AppEnvironment.preview())
}
