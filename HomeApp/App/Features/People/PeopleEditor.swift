import SwiftUI
import HomeCore
import HomeCoreTesting

/// Settings › Housemates (spec 08 FR-INV-01..03, spec 10 FR-SYN-40, mockup 6.3): housemates are name labels with a
/// color — add, rename, recolor, reorder, delete (with a count of what they're tagged on). Pushable (no own
/// `NavigationStack`).
struct PeopleEditor: View {
    @Environment(AppEnvironment.self) private var env

    @State private var propertyId: UUID?
    @State private var people: [Person] = []
    @State private var newName = ""
    @State private var pendingDelete: Person?
    @State private var deleteMessage = ""
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                ForEach(people) { person in
                    PersonEditRow(person: person)
                }
                .onMove(perform: move)
                .onDelete { offsets in
                    if let i = offsets.first { Task { await prepareDelete(people[i]) } }
                }
                HStack {
                    TextField("Add housemate", text: $newName)
                        .submitLabel(.done)
                        .onSubmit { Task { await add() } }
                    Button("Add") { Task { await add() } }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || propertyId == nil)
                }
            } footer: {
                Text("Housemates are name labels for now. Sharing with other people’s iPhones is coming later.")
            }
        }
        .feedbackPage("Housemates")
        .navigationTitle("Housemates")
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "housemate")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { person in
            Button("Delete", role: .destructive) { Task { await delete(person) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(deleteMessage)
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .task { propertyId = try? await env.plan.currentProperty()?.id }
        .task(id: propertyId) {
            guard let pid = propertyId else { return }
            for await list in env.people.observePeople(property: pid) {
                people = list.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            }
        }
    }

    private func add() async {
        guard let pid = propertyId else { return }
        let name = newName
        newName = ""
        if await TIK.addPerson(named: name, env: env, propertyId: pid, existing: people) == nil,
           !name.trimmingCharacters(in: .whitespaces).isEmpty {
            errorText = "Couldn’t add \(name)."
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        people.move(fromOffsets: source, toOffset: destination)
        let ids = people.map(\.id)
        Task {
            do { try await env.people.reorder(ids) } catch { errorText = error.localizedDescription }
        }
    }

    /// FR-INV-03: confirmation shows what the person is tagged on.
    private func prepareDelete(_ person: Person) async {
        guard let pid = propertyId else { return }
        let chores = (try? await env.chores.chores(ChoreQuery(propertyId: pid, assigneeId: person.id)).count) ?? 0
        let items = (try? await env.inventory.items(InventoryQuery(propertyId: pid, ownerId: person.id)).count) ?? 0
        var parts: [String] = []
        if chores > 0 { parts.append("assigned \(chores) to-do\(chores == 1 ? "" : "s")") }
        if items > 0 { parts.append("owner of \(items) item\(items == 1 ? "" : "s")") }
        deleteMessage = parts.isEmpty
            ? "\(person.name) isn’t tagged on anything."
            : "\(person.name) is \(parts.joined(separator: " and ")). They’ll show as Unassigned / No owner."
        pendingDelete = person
    }

    private func delete(_ person: Person) async {
        pendingDelete = nil
        do { try await env.people.delete(person.id) } catch { errorText = error.localizedDescription }
    }
}

/// One housemate: color menu + inline rename (saved on submit / when leaving the row).
private struct PersonEditRow: View {
    @Environment(AppEnvironment.self) private var env
    let person: Person
    @State private var name = ""
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Array(zip(TIK.personPalette, TIK.personPaletteNames)), id: \.0) { hex, colorName in
                    Button {
                        Task { await save(colorHex: hex) }
                    } label: {
                        if hex.uppercased() == person.colorHex?.uppercased() {
                            Label(colorName, systemImage: "checkmark")
                        } else {
                            Text(colorName)
                        }
                    }
                }
            } label: {
                TIK.PersonDot(name: name.isEmpty ? person.name : name, colorHex: person.colorHex, size: 28)
            }
            .accessibilityLabel("Color for \(person.name)")
            TextField("Name", text: $name)
                .submitLabel(.done)
                .onSubmit { Task { await save(colorHex: person.colorHex) } }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = person.name
        }
        .onChange(of: person.name) { _, new in name = new }
        .onDisappear { Task { await save(colorHex: person.colorHex) } }
    }

    private func save(colorHex: String?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? person.name : trimmed
        guard newName != person.name || colorHex != person.colorHex else { return }
        var p = person
        p.name = newName
        p.colorHex = colorHex
        try? await env.people.save(p)
    }
}

#Preview {
    NavigationStack { PeopleEditor() }.environment(AppEnvironment.preview())
}
