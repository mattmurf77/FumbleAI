import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import HomeCore
import HomeCoreTesting

/// Project detail (mockup 4.2, FR-PRJ-10…24): Idea → Planned → In Progress → Done stepper, estimate vs actual (money
/// and hours), line items, receipts with "Scan receipt", "Mark Done…" (DoneSheet) or "Reopen". Push it inside a
/// NavigationStack: `NavigationLink { ProjectDetailView(projectID: p.id) } label: { … }`.
struct ProjectDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID

    @State private var project: Project?
    @State private var missing = false
    @State private var lineItems: [CostLineItem] = []
    @State private var receipts: [Attachment] = []
    @State private var names = SchedulePlaceNames()
    @State private var editing = false
    @State private var showDone = false
    @State private var lineItemSheet: LineItemRoute?
    @State private var scanned: ScannedReceipt?
    @State private var confirmDelete = false
    @State private var errorText: String?
    @State private var receiptsVersion = 0
    @State private var receiptToItem: ScannedReceipt?
    @State private var previewURL: URL?
    @State private var importingReceipt = false
    @State private var savingAttachment = false

    struct LineItemRoute: Identifiable {
        let id = UUID()
        var item: CostLineItem?
        var receipt: ScannedReceipt?
    }

    var body: some View {
        Group {
            if let project { content(project) }
            else if missing { ContentUnavailableView("Project not found", systemImage: "hammer", description: Text("It may have been deleted.")) }
            else { ProgressView() }
        }
        .feedbackPage("Project details")
        .navigationTitle(project.map { names.name($0.scope) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if project != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    } label: { Text("Edit") }
                }
            }
        }
        .sheet(isPresented: $editing) { ProjectForm(projectID: projectID) }
        .sheet(isPresented: $showDone) {
            if let project { DoneSheet(project: project, lineItems: lineItems) { receiptsVersion += 1 } }
        }
        .sheet(item: $lineItemSheet) { route in
            if let project { LineItemEditor(project: project, existing: route.item, receipt: route.receipt) }
        }
        .sheet(item: $scanned, onDismiss: {
            if let receiptToItem {
                lineItemSheet = LineItemRoute(item: nil, receipt: receiptToItem)
                self.receiptToItem = nil
            }
        }) { r in
            ReceiptReviewSheet(receipt: r, currency: project?.currencyCode ?? "USD",
                               onAttach: { Task { await attach(r) } },
                               onAddLineItem: { receiptToItem = r })
        }
        .quickLookPreview($previewURL)
        .fileImporter(isPresented: $importingReceipt, allowedContentTypes: [.pdf, .image]) { result in
            do {
                let file = try result.get()
                Task { await importReceipt(file) }
            } catch let error as CocoaError where error.code == .userCancelled {}
            catch { errorText = error.localizedDescription }
        }
        .confirmationDialog("Delete this project?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: { Text("It moves to Recently Deleted for 30 days.") }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .task { await observeProject() }
        .task { await observeLineItems() }
        .task(id: receiptsVersion) { await loadReceipts() }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ p: Project) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(p)).font(.subheadline).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            }

            Section { ProjectStatusStepper(status: p.status) { select($0, for: p) } }

            if let action = p.workAction, action != .unknown {
                LabeledContent("Type of work", value: action.displayName)
            }
            if p.status.isFuture {
                NavigationLink { ProjectPlanningView(project: p) } label: {
                    Label("Plan costs, quotes and financing", systemImage: "list.clipboard")
                }
            }
            Section("Estimate vs actual") { estimateCard(p) }

            Section {
                if lineItems.isEmpty {
                    Text("No line items yet").foregroundStyle(.secondary)
                }
                ForEach(lineItems) { item in
                    Button { lineItemSheet = LineItemRoute(item: item) } label: { lineItemRow(item) }
                        .foregroundStyle(.primary)
                }
                .onDelete { idx in
                    let ids = idx.map { lineItems[$0].id }
                    Task {
                        do { for id in ids { try await env.projects.deleteLineItem(id) } }
                        catch { errorText = error.localizedDescription }
                    }
                }
                Button { lineItemSheet = LineItemRoute(item: nil) } label: { Label("Add line item", systemImage: "plus") }
            } header: {
                Text("Line items")
            } footer: {
                if p.actualCost != nil && !lineItems.isEmpty {
                    Text("The entered actual cost is used. Line items total \(lineSum(p).formatted()).")
                }
            }

            Section {
                ForEach(receipts) { r in
                    Button {
                        Task { await preview(r) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: r.kind == .document ? "doc.fill" : "doc.text.fill").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.caption ?? (r.kind == .document ? "Document" : "Receipt")).fontWeight(.semibold)
                                Text(receiptSubtitle(r)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if r.ocrText != nil { Text("Scanned").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule()).foregroundStyle(.orange) }
                        }
                    }.foregroundStyle(.primary)
                }
                ReceiptScanButton { scanned = $0 }
                Button { importingReceipt = true } label: { Label("Import receipt from Files", systemImage: "doc.badge.plus") }
                    .disabled(savingAttachment)
                if savingAttachment { ProgressView("Saving receipt") }
            } header: {
                Text("Receipts & documents")
            } footer: {
                Text("Got one by email? Share it from Mail (or Photos, Files) to Home Blueprint, then file it here.")
            }

            if let notes = p.notes, !notes.isEmpty { Section("Notes") { Text(notes) } }

            Section {
                if p.status == .done {
                    Button { Task { await reopen() } } label: { Label("Reopen (move back to In Progress)", systemImage: "arrow.uturn.backward") }
                } else {
                    Button { showDone = true } label: {
                        Label("Mark Done…", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            } footer: {
                if p.status != .done {
                    Text("Asks for the final cost, the date and a receipt, then moves the project to Past Work.")
                }
            }
        }
    }

    private func subtitle(_ p: Project) -> String {
        var parts = [names.path(p.scope)]
        if let v = p.vendor { parts.append(v) }
        if p.status == .done {
            if let c = p.completedOn { parts.append("done \(ScheduleFormat.longDay(c))") }
            else if let year = p.completedYear { parts.append("done in \(year)") }
        }
        else if let s = p.startedOn { parts.append("started \(ScheduleFormat.shortMonths[s.month - 1]) \(s.day)") }
        else if let t = p.targetOn { parts.append("target \(ScheduleFormat.longDay(t))") }
        return parts.joined(separator: " · ")
    }

    private func lineSum(_ p: Project) -> Money {
        Money(cents: lineItems.reduce(0) { $0 + $1.amount.cents }, currency: p.currencyCode)
    }

    @ViewBuilder
    private func estimateCard(_ p: Project) -> some View {
        let spentCents = RollupMath.spentCents(p, lineItems: lineItems)
        let spentHours = RollupMath.spentHours(p, lineItems: lineItems)
        let est = p.estCost?.cents ?? 0
        let showsSpent = p.actualCost != nil || !lineItems.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimate").font(.caption).foregroundStyle(.secondary)
                    Text(p.estCost.map { $0.formatted(showCents: false) } ?? "No estimate").font(.title3.bold())
                    if let h = ScheduleFormat.hours(p.estHours) { Text(h).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(p.status == .done ? "Actual" : "Actual so far").font(.caption).foregroundStyle(.secondary)
                    Text(showsSpent ? Money(cents: spentCents, currency: p.currencyCode).formatted() : "Unrecorded")
                        .font(.title3.bold()).foregroundStyle(Color.accentColor)
                    if let h = ScheduleFormat.hours(spentHours) { Text(h).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if est > 0 && showsSpent {
                ProgressView(value: min(Double(spentCents) / Double(est), 1))
                    .tint(spentCents > est ? Color.red : Color.accentColor)
                Text(progressText(p, spent: spentCents, est: est)).font(.footnote).foregroundStyle(.secondary)
            }
            Text(p.actualCost != nil ? "Entered" : (lineItems.isEmpty ? "No costs yet" : "From \(lineItems.count) line item\(lineItems.count == 1 ? "" : "s")"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func progressText(_ p: Project, spent: Int64, est: Int64) -> String {
        if p.status == .done { return ScheduleFormat.variance(spent - est, currency: p.currencyCode) }
        let pct = (Double(spent) / Double(est) * 100).formatted(.number.precision(.fractionLength(0)))
        let left = Money(cents: max(est - spent, 0), currency: p.currencyCode).formatted(showCents: false)
        return spent > est ? "\(pct)% of estimate used · over by \(Money(cents: spent - est, currency: p.currencyCode).formatted(showCents: false))"
                           : "\(pct)% of estimate used · \(left) left"
    }

    private func lineItemRow(_ item: CostLineItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                Text([item.vendor, item.kind == .unknown ? nil : item.kind.rawValue.capitalized,
                      item.incurredOn.map { ScheduleFormat.longDay($0) }, ScheduleFormat.hours(item.hours)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.amount.formatted())
            if item.receiptAttachmentId != nil {
                Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Receipt")
            }
        }
    }

    private func receiptSubtitle(_ a: Attachment) -> String {
        var parts: [String] = []
        if let d = a.capturedAt { parts.append(ScheduleFormat.longDay(LocalDate(d, calendar: env.clock.calendar))) }
        parts.append(a.fileExt.uppercased())
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func select(_ status: Project.Status, for p: Project) {
        guard status != p.status else { return }
        if status == .done { showDone = true; return }
        Task {
            do {
                if p.status == .done && status == .inProgress { try await env.projects.reopen(p.id) }
                else { try await env.projects.setStatus(p.id, status) }
            } catch { errorText = error.localizedDescription }
        }
    }

    @MainActor
    private func reopen() async {
        do { try await env.projects.reopen(projectID) } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func preview(_ attachment: Attachment) async {
        guard let url = await env.attachments.fileURL(for: attachment) else {
            errorText = "This attachment is unavailable on this iPhone. Check iCloud sync and try again."
            return
        }
        previewURL = url
    }

    @MainActor
    private func importReceipt(_ url: URL) async {
        guard let project, !savingAttachment else { return }
        savingAttachment = true
        defer { savingAttachment = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
            guard file.isRegularFile == true, let size = file.fileSize, (1...Attachment.maxPDFBytes).contains(size),
                  let type = file.contentType, type.conforms(to: .image) || type.conforms(to: .pdf),
                  let ext = type.preferredFilenameExtension else {
                throw RepositoryError.invalid("Choose an image or PDF up to 25 MB.")
            }
            let draft = AttachmentDraft(fileURL: url, kind: .receipt, fileExt: ext, uti: type.identifier,
                                        caption: url.deletingPathExtension().lastPathComponent, capturedAt: env.clock.now)
            _ = try await env.attachments.add(draft, ownerType: .project, ownerId: project.id, property: project.propertyId)
            receiptsVersion += 1
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func attach(_ r: ScannedReceipt) async {
        guard let p = project else { return }
        do {
            _ = try await env.attachments.add(r.attachmentDraft, ownerType: .project, ownerId: p.id, property: p.propertyId)
            receiptsVersion += 1
        } catch { errorText = error.localizedDescription }
    }

    @MainActor
    private func delete() async {
        do { try await env.projects.delete(projectID); dismiss() } catch { errorText = error.localizedDescription }
    }

    // MARK: Data

    @MainActor
    private func observeProject() async {
        guard let property = try? await env.plan.currentProperty() else { missing = true; return }
        names = await SchedulePlaceNames.load(env, property: property.id)
        for await list in env.projects.observeProjects(ProjectQuery(propertyId: property.id)) {
            project = list.first { $0.id == projectID }
            missing = project == nil
        }
    }

    @MainActor
    private func observeLineItems() async {
        for await items in env.projects.observeLineItems(project: projectID) {
            lineItems = items.filter { $0.deletedAt == nil }.sorted { ($0.incurredOn ?? .init(1, 1, 1), $0.createdAt) < ($1.incurredOn ?? .init(1, 1, 1), $1.createdAt) }
            receiptsVersion += 1
        }
    }

    @MainActor
    private func loadReceipts() async {
        var all = ((try? await env.attachments.attachments(ownerType: .project, ownerId: projectID)) ?? [])
            .filter { ($0.kind == .receipt || $0.kind == .document) && $0.deletedAt == nil }
        for item in lineItems where item.receiptAttachmentId != nil {
            let more = (try? await env.attachments.attachments(ownerType: .costLineItem, ownerId: item.id)) ?? []
            all += more.filter { $0.kind == .receipt && $0.deletedAt == nil }
        }
        guard !Task.isCancelled else { return }
        receipts = all.sorted { ($0.capturedAt ?? $0.createdAt) > ($1.capturedAt ?? $1.createdAt) }
    }
}

/// Idea → Planned → In Progress → Done (mockup 4.2). Tapping a step asks the parent to move there.
struct ProjectStatusStepper: View {
    let status: Project.Status
    let onSelect: (Project.Status) -> Void

    private var currentIndex: Int { Project.Status.lifecycleSteps.firstIndex(of: status) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Project.Status.lifecycleSteps.enumerated()), id: \.offset) { i, step in
                if i > 0 {
                    Rectangle()
                        .fill(i <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 18)
                }
                Button { onSelect(step) } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(i < currentIndex ? Color.accentColor : (i == currentIndex ? Color.accentColor.opacity(0.2) : Color.clear))
                                .overlay(Circle().stroke(i <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 2))
                                .frame(width: 18, height: 18)
                            if i < currentIndex {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        Text(step.displayName)
                            .font(.caption2.weight(i == currentIndex ? .semibold : .regular))
                            .foregroundStyle(i == currentIndex ? Color.primary : Color.secondary)
                            .fixedSize()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(step.displayName)
                .accessibilityAddTraits(i == currentIndex ? .isSelected : [])
                .accessibilityHint(i == currentIndex ? "" : "Moves the project to \(step.displayName)")
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview("In progress") {
    NavigationStack { ProjectDetailView(projectID: SampleHome.fridgeProjectId) }
        .environment(AppEnvironment.preview())
}

#Preview("Done") {
    NavigationStack { ProjectDetailView(projectID: SampleHome.bathRemodelId) }
        .environment(AppEnvironment.preview())
}
