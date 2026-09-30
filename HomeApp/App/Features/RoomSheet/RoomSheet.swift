import SwiftUI
import PlanKit
import HomeCore
import PlanCanvas
import HomeCoreTesting

/// The sheet that slides up when a room is tapped (spec 02 FR-CNV-40…43, mockup 3.3). Its body follows the active
/// view: Plan (details, measurements, counts), To-Dos (Overdue/Today/This week/Later with completion circles),
/// Future Projects, Past Work, Things, Inventory (spot tree + loose items) and Budget (rollup card + projects).
/// `RoomSheet(scope:)` shows the same for "This floor" / "Whole house" (FR-CNV-25).
struct RoomSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private let spaceId: UUID?
    private let fixedScope: Scope?
    private let lensOverride: LensID?
    private let onEditShape: ((UUID) -> Void)?

    @State private var model = RoomSheetModel()
    @State private var addRequest: AddRequest?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var completeError: String?
    @State private var openItem: ItemSheetRef?

    /// A room.
    init(spaceId: UUID, lens: LensID? = nil, onEditShape: ((UUID) -> Void)? = nil) {
        self.spaceId = spaceId; self.fixedScope = nil; self.lensOverride = lens; self.onEditShape = onEditShape
    }

    /// "This floor" (`.level`) or "Whole house" (`.property`).
    init(scope: Scope, lens: LensID? = nil) {
        if case .space(let s, _) = scope { self.spaceId = s; self.fixedScope = nil } else { self.spaceId = nil; self.fixedScope = scope }
        self.lensOverride = lens; self.onEditShape = nil
    }

    private var lens: LensID { lensOverride ?? env.selectedLens }
    private var theme: PlanTheme { PlanTheme.forScheme(scheme) }
    private var today: LocalDate { env.clock.today }
    private var unit: UnitSystem { model.property?.unitSystem ?? .imperial }
    private var currency: String { model.property?.currencyCode ?? "USD" }

    private var title: String {
        if let s = model.space { return s.name }
        switch fixedScope {
        case .level: return model.level.map { "This floor · \($0.name)" } ?? "This floor"
        default: return "Whole house"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                switch lens {
                case .plan: planSections
                case .todos: todoSections
                case .futureProjects: futureSections
                case .pastWork: pastSections
                case .things: thingSections
                case .inventory: inventorySections
                case .budget: budgetSections
                }
                Section {
                    Button { requestAdd(preselect: lens.addDefault) } label: {
                        Label(addButtonTitle, systemImage: "plus.circle.fill").font(.body.weight(.semibold))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { requestAdd(preselect: lens.addDefault) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add item")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ItemRef.self) { ref in
                switch ref {
                case .chore(let id): ChoreDetailView(choreID: id)
                default: ItemDetailRouter(ref: ref)
                }
            }
            .overlay {
                if model.missing {
                    ContentUnavailableView("Room not found", systemImage: "questionmark.square.dashed",
                                           description: Text("It may have been deleted."))
                }
            }
        }
        .feedbackPage("Room · " + title, context: ["lens": lens.rawValue])
        .task(id: spaceId ?? fixedScope?.levelId) { await model.run(env: env, spaceId: spaceId, scope: fixedScope) }
        .sheet(item: $openItem) { item in ItemDetailRouter(ref: item.ref) }
        .sheet(item: $addRequest) { r in
            AddPicker(spaceID: r.spaceID, levelID: r.levelID, preselected: r.preselected, placeName: r.placeName, outdoor: r.outdoor)
        }
        .alert("Rename room", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn’t update", isPresented: Binding(get: { completeError != nil }, set: { if !$0 { completeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(completeError ?? "") }
    }

    // MARK: Header (FR-CNV-41)

    @ViewBuilder
    private var headerSection: some View {
        if let s = model.space {
            Section {
                Button { renameText = s.name; renaming = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.name).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                            Text(roomSubtitle(s)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "pencil").foregroundStyle(.tertiary)
                    }
                }
                .accessibilityHint("Rename")
            }
        }
    }

    private func roomSubtitle(_ s: Space) -> String {
        let dims = LensFormat.primes(HomeLengthFormatter.dimensionText(for: s.polygon, isApproximate: s.isApproximate, system: unit))
        return [s.spaceType == .room ? nil : s.spaceType.displayName, dims,
                HomeLengthFormatter.formatArea(squareInches: s.areaSqIn, system: unit)].compactMap { $0 }.joined(separator: " · ")
    }

    private var addButtonTitle: String {
        switch lens.addDefault {
        case .todo: return "Add To-Do"
        case .futureProject: return "Add Future Project"
        case .pastWork: return "Log Past Work"
        case .thing: return isOutdoor ? "Add Plant or outdoor feature" : "Add Appliance, Electronic or Furniture"
        case .inventory: return "Add Inventory item"
        case .measurement: return "Add Measurement"
        case nil: return "Add…"
        }
    }

    private func requestAdd(preselect: AddKind?) {
        addRequest = AddRequest(spaceID: model.space?.id, levelID: model.space?.levelId ?? fixedScope?.levelId,
                                preselected: preselect, placeName: model.space?.name, outdoor: isOutdoor)
    }

    private var isOutdoor: Bool { model.level?.isExterior == true || model.space?.isExterior == true }

    private func commitRename() {
        guard let id = model.space?.id else { return }
        let name = String(renameText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty else { return }
        Task { try? await env.plan.renameSpace(id, to: name) }
    }

    /// Chores push their detail screen; other items open their (self-contained, modal) edit form.
    @ViewBuilder
    private func itemLink<Content: View>(_ ref: ItemRef, @ViewBuilder _ content: () -> Content) -> some View {
        switch ref {
        case .chore:
            NavigationLink(value: ref) { content() }
        default:
            Button { openItem = ItemSheetRef(ref: ref) } label: {
                HStack(spacing: 6) {
                    content()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
    }

    // MARK: Plan

    @ViewBuilder
    private var planSections: some View {
        if let s = model.space {
            Section("Details") {
                LabeledContent("Dimensions", value: LensFormat.primes(HomeLengthFormatter.dimensionText(for: s.polygon, isApproximate: s.isApproximate, system: unit)))
                LabeledContent("Area", value: HomeLengthFormatter.formatArea(squareInches: s.areaSqIn, system: unit))
                LabeledContent("Created", value: sourceText(s.source))
                if !model.openings.isEmpty {
                    let doors = model.openings.filter { $0.kind == .door }.count
                    let windows = model.openings.filter { $0.kind == .window }.count
                    LabeledContent("Doors & windows", value: "\(doors) doors · \(windows) windows")
                }
                if let onEditShape {
                    Button { dismiss(); onEditShape(s.id) } label: { Label("Edit shape", systemImage: "square.and.pencil") }
                }
            }
            Section("Measurements") {
                if model.measurements.isEmpty {
                    empty("No measurements. Measure openings, walls and doors for fit checks.")
                } else {
                    ForEach(model.measurements) { m in
                        itemLink(.measurement(m.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.label)
                                Text(measurementLine(m)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        Section("In this \(model.space == nil ? "place" : "room")") {
            countRow("To-Dos", model.openChores.count, lens: .todos)
            countRow("Future Projects", model.futureProjects.count, lens: .futureProjects)
            countRow("Past Work", model.pastProjects.count, lens: .pastWork)
            countRow("Appliances, Electronics & Furniture", model.things.count, lens: .things)
            countRow("Inventory", model.items.count, lens: .inventory)
        }
    }

    private func countRow(_ label: String, _ n: Int, lens target: LensID) -> some View {
        Button { env.selectedLens = target } label: {
            HStack {
                Label(label, systemImage: target.symbol).foregroundStyle(.primary)
                Spacer()
                Text("\(n)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("Switches the plan to this view")
    }

    private func measurementLine(_ m: HomeMeasurement) -> String {
        var parts: [String] = []
        if let w = m.dims.width { parts.append("\(HomeLengthFormatter.formatInches(w, system: unit)) W") }
        if let d = m.dims.depth { parts.append("\(HomeLengthFormatter.formatInches(d, system: unit)) D") }
        var s = parts.joined(separator: " × ")
        if let h = m.dims.height { s += (s.isEmpty ? "" : ", ") + "\(HomeLengthFormatter.formatInches(h, system: unit)) H" } else if !s.isEmpty { s += ", height not set" }
        if m.isDeliveryPath { s += " · delivery path" }
        return s
    }

    private func sourceText(_ s: Space.Source) -> String {
        switch s {
        case .roomplan: return "from a room scan"
        case .blocks: return "from Build with blocks"
        case .trace: return "from a traced floor plan"
        case .rough: return "from Rough it in"
        case .autoseed: return "from the address outline"
        case .manual: return "drawn by hand"
        case .unknown: return "—"
        }
    }

    // MARK: To-Dos

    @ViewBuilder
    private var todoSections: some View {
        let groups = model.choreGroups(today: today)
        if groups.isEmpty {
            Section { empty("No chores here yet. Add a repeating chore like “Wipe counters, daily.”") }
        }
        ForEach(groups) { g in
            Section {
                ForEach(g.chores) { c in choreRow(c) }
            } header: {
                Text(g.title).foregroundStyle(g.isDanger ? theme.danger : Color.secondary)
            }
        }
    }

    private func choreRow(_ c: Chore) -> some View {
        HStack(spacing: 12) {
            Button { complete(c) } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(c.isOverdue(today: today) ? theme.danger : Color.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(c.title)")
            itemLink(.chore(c.id)) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).lineLimit(2)
                        let sub = [c.repeatRule?.humanText, c.linkedThingId.flatMap { model.thingNames[$0] }].compactMap { $0 }
                        if !sub.isEmpty { Text(sub.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 6)
                    if let who = c.assigneeId.flatMap({ model.people[$0] }) { avatar(who) }
                    Text(dueText(c))
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(c.isOverdue(today: today) ? theme.danger : Color.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Skip") { Task { do { try await env.chores.skip(c.id, at: env.clock.now) } catch { completeError = "\(error)" } } }.tint(.orange)
            Button("Delete", role: .destructive) { Task { try? await env.chores.delete(c.id) } }
        }
    }

    private func avatar(_ p: Person) -> some View {
        Text(String(p.name.prefix(1)).uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(theme.personColor(p.colorHex)))
            .accessibilityLabel(p.name)
    }

    private func dueText(_ c: Chore) -> String {
        guard let due = c.nextDueOn else { return c.isPaused ? "Paused" : "" }
        if c.isPaused { return "Paused" }
        let d = today.days(until: due)
        if d < 0 { return "\(-d)d late" }
        if d == 0 { return "Today" }
        if d == 1 { return "Tomorrow" }
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        if d < 7 { return "\(names[(due.weekday - 1) % 7]) \(due.day)" }
        return LensFormat.monthDay(due)
    }

    private func complete(_ c: Chore) {
        Task {
            do { _ = try await env.chores.complete(c.id, by: nil, at: env.clock.now) } catch { completeError = "\(error)" }
        }
    }

    // MARK: Future Projects

    @ViewBuilder
    private var futureSections: some View {
        let ps = model.futureProjects
        Section {
            if ps.isEmpty {
                empty("No planned projects. Add an idea with a rough estimate. You can refine it later.")
            } else {
                ForEach(ps) { p in
                    itemLink(.project(p.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.title)
                                statusTag(p.status)
                            }
                            Spacer()
                            if let est = p.estCost { Text(LensFormat.money(est.cents, currency: est.currency)).monospacedDigit().foregroundStyle(theme.accent) }
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { Task { try? await env.projects.delete(p.id) } } }
                }
            }
        } header: {
            if !ps.isEmpty {
                Text("\(LensFormat.count(ps.count, "project")) · \(LensFormat.money(model.rollup?.plannedCents ?? 0, currency: currency)) planned")
            }
        }
    }

    private func statusTag(_ s: Project.Status) -> some View {
        Text(s.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(s == .inProgress ? theme.onAccent : theme.ink2)
            .background(Capsule().fill(s == .inProgress ? theme.accent : theme.surface2))
    }

    // MARK: Past Work

    @ViewBuilder
    private var pastSections: some View {
        let ps = model.pastProjects
        Section {
            if ps.isEmpty {
                empty("No past work logged. Log finished work with its cost, date and receipt.")
            } else {
                ForEach(ps) { p in
                    itemLink(.project(p.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title)
                                let date = p.completedOn.map { LensFormat.monthYear($0) } ?? ""
                                let est = p.estCost.map { "est \(LensFormat.money($0.cents, currency: $0.currency))" }
                                Text([date, est].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let a = p.actualCost { Text(LensFormat.money(a.cents, currency: a.currency)).monospacedDigit() }
                        }
                    }
                }
            }
        } header: {
            if !ps.isEmpty { Text("\(LensFormat.count(ps.count, "job")) · \(LensFormat.money(model.lifetimeCents, currency: currency)) lifetime") }
        }
    }

    // MARK: Things

    @ViewBuilder
    private var thingSections: some View {
        if model.things.isEmpty {
            Section { empty(isOutdoor ? "Nothing tracked here. Add trees, flowers, a patio, grill or shed."
                                      : "Nothing tracked here. Add appliances, bulbs, filters or furniture.") }
        }
        ForEach(model.thingsByCategory) { group in
            Section(categoryTitle(group.category)) {
                ForEach(group.things) { t in
                    itemLink(.thing(t.id)) {
                        HStack(spacing: 12) {
                            Image(systemName: planSymbolName(t.symbol)).foregroundStyle(theme.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(t.name)
                                    if t.ownership == .planned { tag("Planned", theme.accentSoft, theme.accent) }
                                }
                                let spec = [t.brand, t.model].compactMap { $0 }.joined(separator: " ")
                                if !spec.isEmpty { Text(spec).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let w = t.warrantyEnd, today.days(until: w) >= 0, today.days(until: w) <= 60 {
                                tag("Warranty ends \(LensFormat.monthYear(w))", theme.warnSoft, theme.warn)
                            }
                        }
                    }
                }
            }
        }
    }

    private func categoryTitle(_ c: Thing.Category) -> String {
        switch c {
        case .appliance: return "Appliances"; case .electronic: return "Electronics"; case .furniture: return "Furniture"
        case .fixture: return "Fixtures"; case .system: return "Systems"; case .outdoor: return "Outdoor"; case .unknown: return "Other"
        }
    }

    private func tag(_ text: String, _ bg: Color, _ fg: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(fg).background(Capsule().fill(bg))
    }

    // MARK: Inventory

    @ViewBuilder
    private var inventorySections: some View {
        if model.spotTree.isEmpty && model.items.isEmpty {
            Section { empty("No storage spots. Add a shelf, bin or drawer, then add items to it.") }
        }
        if !model.spotTree.isEmpty {
            Section("Storage spots") {
                ForEach(model.spotTree) { node in SpotTreeRow(node: node, items: model.items, theme: theme) }
            }
        }
        if !model.looseItems.isEmpty {
            Section(model.spotTree.isEmpty ? "Items" : "Not in a spot") {
                ForEach(model.looseItems) { item in itemRow(item) }
            }
        }
    }

    private func itemRow(_ item: InventoryItem) -> some View {
        itemLink(.inventory(item.id)) {
            HStack {
                Text(item.name)
                Spacer()
                if item.isLow { tag("Low", theme.warnSoft, theme.warn) }
                Text(quantityText(item)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func quantityText(_ i: InventoryItem) -> String {
        let q = i.quantity.rounded() == i.quantity ? String(Int(i.quantity)) : String(format: "%.1f", i.quantity)
        return [q, i.unit].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Budget

    @ViewBuilder
    private var budgetSections: some View {
        let r = model.rollup ?? Rollup(currency: currency)
        if r.isEmpty {
            Section { empty("No money tracked in this room yet. Add a Future Project to start a budget.") }
        } else {
            Section("Budget") {
                LabeledContent("Planned") { Text(LensFormat.money(r.plannedCents, currency: currency)).foregroundStyle(theme.accent).monospacedDigit() }
                LabeledContent("Spent") { Text(LensFormat.money(r.spentCents, currency: currency)).monospacedDigit() }
                LabeledContent("Remaining") { Text(LensFormat.money(r.remainingCents, currency: currency)).monospacedDigit() }
                if r.ideaCount > 0 {
                    LabeledContent("Ideas (not in planned)") { Text(LensFormat.money(r.ideaCents, currency: currency)).monospacedDigit() }
                }
                if r.doneCount > 0 {
                    LabeledContent("Variance on done work") {
                        Text((r.varianceCents > 0 ? "+" : "") + LensFormat.money(r.varianceCents, currency: currency))
                            .foregroundStyle(r.varianceCents > 0 ? theme.danger : theme.ok).monospacedDigit()
                    }
                }
                if r.plannedHours > 0 || r.spentHours > 0 {
                    LabeledContent("Hours", value: "\(hours(r.spentHours)) of \(hours(r.plannedHours)) h")
                }
            }
            Section("Projects") {
                ForEach(model.projects.sorted { $0.title < $1.title }) { p in
                    itemLink(.project(p.id)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) { Text(p.title); statusTag(p.status) }
                            Spacer()
                            if p.status == .done, let a = p.actualCost {
                                Text(LensFormat.money(a.cents, currency: a.currency)).monospacedDigit()
                            } else if let e = p.estCost {
                                Text(LensFormat.money(e.cents, currency: e.currency)).monospacedDigit().foregroundStyle(theme.accent)
                            }
                        }
                    }
                }
            }
        }
    }

    private func hours(_ h: Double) -> String { h.rounded() == h ? String(Int(h)) : String(format: "%.1f", h) }
}

/// One storage spot with its children (expandable) and counts.
private struct SpotTreeRow: View {
    let node: SpotNode
    let items: [InventoryItem]
    let theme: PlanTheme

    var body: some View {
        if node.children.isEmpty {
            label
        } else {
            DisclosureGroup {
                ForEach(node.children) { SpotTreeRow(node: $0, items: items, theme: theme) }
            } label: { label }
        }
    }

    private var label: some View {
        let low = items.filter { $0.storageSpotId == node.spot.id && $0.isLow }.count
        return HStack {
            Image(systemName: "shippingbox").foregroundStyle(theme.accent)
            Text(node.spot.name)
            Spacer()
            if low > 0 {
                Text("\(low) low").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(theme.warn).background(Capsule().fill(theme.warnSoft))
            }
            Text("\(node.subtreeItemCount)").monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ItemSheetRef: Identifiable, Hashable {
    let ref: ItemRef
    var id: ItemRef { ref }
}

/// Opens a non-chore item from a room-sheet row, modally. INTEGRATION: swap the edit forms for dedicated detail
/// screens as the owning features add them (only chores have a pushable detail screen today).
struct ItemDetailRouter: View {
    let ref: ItemRef
    var body: some View {
        switch ref {
        case .chore(let id): NavigationStack { ChoreDetailView(choreID: id) }
        case .project(let id): ProjectForm(projectID: id)
        case .thing(let id): ThingForm(thingID: id)
        case .inventory(let id): InventoryForm(itemID: id)
        case .measurement(let id): MeasurementForm(measurementID: id)
        }
    }
}

#Preview("Kitchen · To-Dos") {
    RoomSheet(spaceId: SampleHome.kitchenId, lens: .todos).environment(AppEnvironment.preview())
}

#Preview("Kitchen · Plan") {
    RoomSheet(spaceId: SampleHome.kitchenId).environment(AppEnvironment.preview())
}

#Preview("Whole house · Budget") {
    RoomSheet(scope: .property, lens: .budget).environment(AppEnvironment.preview())
}
