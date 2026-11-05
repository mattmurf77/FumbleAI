import SwiftUI
import HomeCore

/// A form stages changes until its parent is saved. A saved owner's detail screen writes only its estimates.
struct WorkEstimateLink: View {
    @Environment(AppEnvironment.self) private var env
    let propertyId: UUID
    let currency: String
    let country: String?
    let title: String
    var preferredMode: Chore.WorkMode?
    var owner: WorkEstimateOwner?
    var staged: [WorkEstimate] = []
    var stage: (([WorkEstimate]) -> Void)?
    var useCostLabel = "Use estimate"
    var useCost: ((Money) -> Void)?
    @State private var showing = false
    @State private var stored: [WorkEstimate] = []

    private var scenarios: [WorkEstimate] {
        stored.filter { old in !staged.contains { $0.mode == old.mode } } + staged
    }

    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(scenarios.isEmpty ? "Estimate this work" : "Review work estimate", systemImage: "function")
                ForEach(scenarios, id: \.mode) { plan in
                    Text(plan.mode.label + " · " + estimateAmount(plan)).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("estimate.open")
        .task(id: owner) {
            if let owner, let result = try? await env.estimates.estimates(owner: owner, propertyId: propertyId) { stored = result }
        }
        .sheet(isPresented: $showing) {
            WorkEstimateEditor(propertyId: propertyId, currency: currency, country: country, title: title,
                               preferredMode: preferredMode, owner: owner, staged: staged) { changes in
                if let stage {
                    stage(staged.filter { old in !changes.contains { $0.mode == old.mode } } + changes)
                } else if let owner {
                    try await env.estimates.saveEstimates(changes, owner: owner, propertyId: propertyId)
                    stored = stored.filter { old in !changes.contains { $0.mode == old.mode } } + changes
                }
            }
        }
        if let useCost {
            let ready = scenarios.filter { (try? $0.totals().isComplete) == true }
            if !ready.isEmpty {
                Menu(useCostLabel) {
                    ForEach(ready, id: \.mode) { estimate in
                        if let totals = try? estimate.totals(), let low = totals.knownLow, let high = totals.knownHigh {
                            if low == high {
                                Button(estimate.mode.label + " · " + low.formatted()) { useCost(low) }
                            } else {
                                Button(estimate.mode.label + " · Low " + low.formatted()) { useCost(low) }
                                Button(estimate.mode.label + " · High " + high.formatted()) { useCost(high) }
                            }
                        }
                    }
                }.accessibilityIdentifier("estimate.useCost")
            }
        }
    }
}

func estimateAmount(_ plan: WorkEstimate) -> String {
    guard let totals = try? plan.totals(), let low = totals.knownLow, let high = totals.knownHigh else {
        return plan.lines.isEmpty ? "Add costs to estimate" : "Quantities or rates needed"
    }
    let amount = low == high ? low.formatted() : low.formatted() + "–" + high.formatted()
    return totals.isComplete ? amount : amount + " known so far"
}

private struct WorkEstimateEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let propertyId: UUID
    let currency: String
    let country: String?
    let title: String
    let preferredMode: Chore.WorkMode?
    let owner: WorkEstimateOwner?
    let staged: [WorkEstimate]
    let save: ([WorkEstimate]) async throws -> Void
    @State private var plans: [WorkEstimate] = []
    @State private var changed: Set<Chore.WorkMode> = []
    @State private var mode = Chore.WorkMode.diy
    @State private var lineEditor: WorkEstimateLine?
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var showStarter = false
    @State private var editScope = false
    @State private var showRecords = false
    @State private var replacement: WorkEstimateLine?
    @State private var pickedRecord: WorkEstimateLine?
    @State private var confirmItemize = false
    @State private var replacingWholeJob = false

    private var plan: WorkEstimate { plans.first { $0.mode == mode } ?? WorkEstimate(mode: mode, currency: currency) }
    private var suggested: CustomScopeStarter? {
        guard let starter = CustomScopeStarter.suggested(for: title, mode: mode), guideAllowed || starter.needsDimensions else { return nil }
        return starter
    }
    private var guideAllowed: Bool { currency == "USD" && (country == nil || country?.uppercased() == "US") }

    private var guidePreview: WorkEstimate? {
        guard guideAllowed, plan.lines.isEmpty, let suggested else { return nil }
        let size = CustomScopeStarter.roomSize(in: title)
        guard let rows = try? suggested.lines(length: size?.length, width: size?.width, heightOrDepth: nil,
                                              coats: 2, openings: 0, currency: currency, mode: mode) else { return nil }
        return WorkEstimate(mode: mode, currency: currency, lines: rows)
    }

    var body: some View {
        NavigationStack {
            Form {
                if loaded {
                    Section {
                        Picker("Who will do the work?", selection: $mode) {
                            ForEach(Chore.WorkMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("estimate.mode")
                        VStack(alignment: .leading, spacing: 5) {
                            if let guidePreview {
                                Text("US guide preview").font(.caption).foregroundStyle(.secondary)
                                Text(estimateAmount(guidePreview)).font(.title2.bold()).accessibilityIdentifier("estimate.guidePreview")
                                Text("Review the scope and prices to use this guide.").font(.footnote)
                            } else {
                                Text(estimateAmount(plan)).font(.title2.bold()).accessibilityIdentifier("estimate.total")
                            }
                            if let totals = try? plan.totals() {
                                if totals.unpricedLineCount > 0 {
                                    Text("\(totals.unpricedLineCount) cost item(s) still need a quantity or rate.").font(.footnote)
                                }
                                if mode == .diy, totals.ownHours > 0 { Text("Your time: " + totals.ownHours.formatted() + " hours").font(.footnote) }
                                if totals.hasUnknownOwnHours { Text("Your labor hours are unrecorded.").font(.footnote) }
                            }
                        }
                    } header: { Text(title.isEmpty ? "Cost estimate" : title) }

                    Section("Scope") {
                        if let quantity = plan.scopeQuantity { LabeledContent("Measured scope", value: quantity.formatted() + " " + plan.scopeUnit) }
                        if let assumptions = plan.assumptions, !assumptions.isEmpty {
                            Text(assumptions).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Button(plan.scopeQuantity == nil && plan.assumptions == nil ? "Add measurements or assumptions" : "Edit measurements and assumptions") { editScope = true }
                        Button("Use a past cost or quote") { showRecords = true }
                            .accessibilityIdentifier("estimate.useRecord")
                        Button { showStarter = true } label: {
                            Label(suggested.map { "Estimate with " + $0.title } ?? "Choose a scope guide", systemImage: "ruler")
                        }.accessibilityIdentifier("estimate.starter")
                    }

                    Section {
                        ForEach(plan.lines) { line in
                            Button { replacingWholeJob = false; lineEditor = line } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(line.name).foregroundStyle(.primary)
                                        Text(line.kind.estimateLabel + " · " + estimateQuantityLabel(line, plan: plan))
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(estimateAmount(WorkEstimate(mode: mode, currency: currency, lines: [line])))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.accessibilityIdentifier("estimate.line." + line.name)
                        }
                        let wholeJob = plan.lines.contains { $0.kind == .wholeJob }
                        Button {
                            if wholeJob { confirmItemize = true } else { addItem(replacing: false) }
                        } label: {
                            Label(wholeJob ? "Build an itemized estimate" : "Add a cost item", systemImage: "plus")
                        }.accessibilityIdentifier("estimate.addLine")
                            .confirmationDialog("Replace the whole-job total with individual costs?", isPresented: $confirmItemize, titleVisibility: .visible) {
                                Button("Start itemizing") { addItem(replacing: true) }
                            } message: { Text("Your first saved cost item will replace this total.") }
                    } header: { Text("Itemized costs · " + currency) } footer: {
                        Text("Use prices from a store or written quote. Include delivery, tax and permits when they apply. Estimates are saved on this device.")
                    }
                } else if error == nil { ProgressView("Opening estimate…") }
                if let error {
                    Text(error).foregroundStyle(.red)
                    if !loaded { Button("Retry") { Task { await load() } } }
                }
            }
            .navigationTitle("Work estimate").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save estimate") { Task { await commit() } }.disabled(changed.isEmpty || saving)
                        .accessibilityIdentifier("estimate.save")
                }
            }
            .sheet(item: $lineEditor) { item in
                EstimateLineEditor(line: item, plan: plan, propertyId: propertyId, country: country) { updated in
                    var revised = plan
                    if let index = revised.lines.firstIndex(where: { $0.id == item.id }) {
                        if let updated { revised.lines[index] = updated } else { revised.lines.remove(at: index) }
                    } else if let updated {
                        if replacingWholeJob { revised.lines = [updated]; revised.assumptions = nil }
                        else { revised.lines.append(updated) }
                    }
                    update(revised)
                }
            }
            .sheet(isPresented: $showRecords, onDismiss: {
                guard let line = pickedRecord else { return }
                pickedRecord = nil
                if plan.lines.isEmpty { useRecord(line) } else { replacement = line }
            }) {
                EstimateRecordPicker(propertyId: propertyId, currency: currency, title: title) { pickedRecord = $0 }
            }
            .confirmationDialog("Replace this method’s itemized costs?", isPresented: Binding(get: { replacement != nil }, set: { if !$0 { replacement = nil } }),
                                titleVisibility: .visible, presenting: replacement) { line in
                Button("Use record instead", role: .destructive) { useRecord(line) }
            } message: { _ in Text("The selected job total will become this method’s estimate.") }
            .sheet(isPresented: $editScope) { EstimateScopeEditor(plan: plan, done: update) }
            .sheet(isPresented: $showStarter) { EstimateStarterView(jobTitle: title, plan: plan, suggested: suggested, useUSPrices: guideAllowed, done: update) }
            .task { await load() }
        }
    }

    private func addItem(replacing: Bool) {
        replacingWholeJob = replacing
        lineEditor = WorkEstimateLine(kind: .material, name: "", quantity: 1)
    }

    private func useRecord(_ line: WorkEstimateLine) {
        update(WorkEstimate(mode: mode, currency: currency, lines: [line], assumptions: "Whole-job comparison from a saved home record. Check scope and date against the planned work."))
    }

    private func update(_ estimate: WorkEstimate) {
        plans.removeAll { $0.mode == estimate.mode }
        plans.append(estimate)
        changed.insert(estimate.mode)
    }

    @MainActor private func load() async {
        guard !loaded else { return }
        do {
            let stored: [WorkEstimate]
            if let owner { stored = try await env.estimates.estimates(owner: owner, propertyId: propertyId) }
            else { stored = [] }
            plans = stored.filter { old in !staged.contains { $0.mode == old.mode } } + staged
            mode = preferredMode ?? plans.first?.mode ?? .diy
            error = nil
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func commit() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let updates = plans.filter { changed.contains($0.mode) }
            try WorkEstimate.validate(updates, currency: currency)
            try await save(updates)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

func estimateQuantityLabel(_ line: WorkEstimateLine, plan: WorkEstimate) -> String {
    guard let required = line.quantity else { return "Quantity needed" }
    if let pack = line.packSize, let count = try? plan.purchaseQuantity(for: line) {
        return "Buy " + count.formatted() + " × " + pack.formatted() + " " + line.unit
    }
    return required.formatted() + " " + line.unit
}

extension WorkEstimateLine.Kind {
    var estimateLabel: String {
        switch self { case .material: "Materials"; case .labor: "Labor"; case .equipment: "Equipment or rental"; case .fee: "Fee"; case .wholeJob: "Whole job" }
    }
}
