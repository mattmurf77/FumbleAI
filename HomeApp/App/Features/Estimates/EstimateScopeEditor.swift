import SwiftUI
import HomeCore

struct EstimateScopeEditor: View {
    @Environment(\.dismiss) private var dismiss
    let plan: WorkEstimate
    let done: (WorkEstimate) -> Void
    @State private var quantity: String
    @State private var unit: String
    @State private var notes: String
    @State private var error: String?

    init(plan: WorkEstimate, done: @escaping (WorkEstimate) -> Void) {
        self.plan = plan; self.done = done
        _quantity = State(initialValue: estimateNumberText(plan.scopeQuantity))
        _unit = State(initialValue: plan.scopeUnit)
        _notes = State(initialValue: plan.assumptions ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EstimateNumberField(title: "Measured amount", text: $quantity, id: "estimate.scope.quantity")
                    TextField("Unit, e.g. sq ft, linear ft or fixtures", text: $unit)
                } footer: { Text("Use the scope guide to calculate item quantities from dimensions, or set quantities on each cost item.") }
                Section("Assumptions and terms") {
                    TextField("What is included or excluded?", text: $notes, axis: .vertical).lineLimit(3...10)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Measurements and assumptions").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        do {
                            var update = plan
                            update.scopeQuantity = try estimateNumber(quantity)
                            update.scopeUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
                            update.assumptions = notes.isEmpty ? nil : notes
                            _ = try update.totals()
                            done(update); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

struct EstimateStarterView: View {
    @Environment(\.dismiss) private var dismiss
    let plan: WorkEstimate
    let done: (WorkEstimate) -> Void
    let useUSPrices: Bool
    @State private var starter: CustomScopeStarter
    @State private var length: String
    @State private var width: String
    @State private var height = "8"
    @State private var depth = "3"
    @State private var coats = 2
    @State private var openings = "0"
    @State private var confirm = false

    init(jobTitle: String, plan: WorkEstimate, suggested: CustomScopeStarter?, useUSPrices: Bool, done: @escaping (WorkEstimate) -> Void) {
        self.plan = plan; self.done = done
        self.useUSPrices = useUSPrices
        _starter = State(initialValue: suggested ?? .interiorPaint)
        let size = CustomScopeStarter.roomSize(in: jobTitle)
        _length = State(initialValue: size.map { estimateNumberText(Decimal($0.length)) } ?? "")
        _width = State(initialValue: size.map { estimateNumberText(Decimal($0.width)) } ?? "")
    }

    private var preview: Result<WorkEstimate, Error> {
        Result {
            let length = try estimateNumber(length), width = try estimateNumber(width)
            let vertical = try estimateNumber(starter == .interiorPaint ? height : depth)
            let openings = try estimateNumber(openings) ?? 0
            func double(_ value: Decimal?) -> Double? { value.map { NSDecimalNumber(decimal: $0).doubleValue } }
            var lines = try starter.lines(length: double(length), width: double(width), heightOrDepth: double(vertical),
                                          coats: coats, openings: double(openings) ?? 0, currency: plan.currency, mode: plan.mode)
            if !useUSPrices {
                for index in lines.indices { lines[index].unitPrice = nil; lines[index].highUnitPrice = nil }
            }
            var result = WorkEstimate(mode: plan.mode, currency: plan.currency, lines: lines)
            var notes = [starter.title]
            if starter.needsDimensions, let length, let width {
                result.scopeQuantity = length * width
                result.scopeUnit = "sq ft footprint"
                notes.append(estimateNumberText(length) + " × " + estimateNumberText(width) + " ft.")
                if starter == .interiorPaint, plan.mode == .diy { notes.append("Walls " + height + " ft high, " + String(coats) + " coat(s), " + estimateNumberText(openings) + " sq ft of openings excluded.") }
                if starter == .mulchBeds { notes.append("Mulch depth " + depth + " in.") }
            }
            notes.append(starter.assumptions)
            result.assumptions = notes.joined(separator: " ")
            _ = try result.totals()
            return result
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scope guide", selection: $starter) {
                        ForEach(CustomScopeStarter.allCases.filter { $0.needsDimensions || (plan.mode == .hirePro && useUSPrices) }, id: \.self) {
                            Text($0.title).tag($0)
                        }
                    }
                    if starter.needsDimensions {
                        EstimateNumberField(title: "Length (ft)", text: $length, id: "estimate.starter.length")
                        EstimateNumberField(title: "Width (ft)", text: $width, id: "estimate.starter.width")
                        if starter == .interiorPaint, plan.mode == .diy {
                            EstimateNumberField(title: "Wall height (ft)", text: $height, id: "estimate.starter.height")
                            Stepper("Coats: \(coats)", value: $coats, in: 1...5)
                            EstimateNumberField(title: "Opening area (sq ft)", text: $openings, id: "estimate.starter.openings")
                        }
                        if starter == .mulchBeds { EstimateNumberField(title: "Depth (in)", text: $depth, id: "estimate.starter.depth") }
                    }
                }
                Section(useUSPrices ? "US planning guide" : "Measured quantities") {
                    if !useUSPrices { Text("Add local unit prices in " + plan.currency + " after applying this scope.").font(.footnote) }
                    switch preview {
                    case .success(let result):
                        Text(estimateAmount(result)).font(.title2.bold()).accessibilityIdentifier("estimate.starter.total")
                        ForEach(result.lines) { line in LabeledContent(line.name, value: estimateQuantityLabel(line, plan: result)) }
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundStyle(.secondary)
                    }
                    Text(starter.assumptions).font(.footnote)
                    ForEach(starter.sources, id: \.url) { Link($0.label, destination: $0.url) }
                }
                if case .success(let result) = preview {
                    Button(useUSPrices ? "Use this scope and pricing" : "Use measured quantities") {
                        if plan.lines.isEmpty { done(result); dismiss() } else { confirm = true }
                    }.accessibilityIdentifier("estimate.starter.apply")
                        .confirmationDialog("Replace this method’s existing cost items?", isPresented: $confirm, titleVisibility: .visible) {
                            Button("Replace cost items", role: .destructive) { done(result); dismiss() }
                        } message: { Text("This guide supplies a full breakdown. You can edit its quantities and rates before saving.") }
                }
            }
            .navigationTitle("Scope and unit prices").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
