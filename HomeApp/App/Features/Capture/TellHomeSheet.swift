import SwiftUI
import HomeCore
import HomeCoreTesting
#if canImport(UIKit)
import UIKit
#endif

/// "Tell Home": say or type anything — "we're thinking of getting a new fence in 3 months, about 10k" or "add a task
/// to change the HVAC filter every 3 months" — and Home files it. `SmartCapture` turns the words into proposed to-dos
/// and project ideas (title, amount, date, repeat) shown as editable cards; Save creates them. Self-contained (own
/// `NavigationStack`); present it in a sheet.
struct TellHomeSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// One proposed item, editable before saving.
    struct Card: Identifiable, Hashable {
        let id = UUID()
        var include = true
        var kind: SmartCapture.Kind
        var title: String
        var amountText: String
        var hasDate: Bool
        var date: LocalDate
        var repeatRule: RepeatRule?
        var scope: Scope = .property
        var source: String
    }

    let initialText: String
    let startListening: Bool
    let onSaved: ((Int) -> Void)?

    @State private var text: String
    @State private var cards: [Card] = []
    /// The text the cards were read from (cards are re-read only when the words change).
    @State private var readText = ""
    @State private var dictation = SpeechDictation()
    @State private var places = TIK.PlaceIndex()
    @State private var propertyId: UUID?
    @State private var currency = "USD"
    @State private var saving = false
    @State private var errorText: String?
    @FocusState private var editorFocused: Bool

    init(initialText: String = "", startListening: Bool = false, onSaved: ((Int) -> Void)? = nil) {
        self.initialText = initialText
        self.startListening = startListening
        self.onSaved = onSaved
        _text = State(initialValue: initialText)
    }

    private var included: [Card] {
        cards.filter { $0.include && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var currentText: String { dictation.isRecording ? dictation.transcript : text }
    private var today: LocalDate { env.clock.today }

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                ForEach($cards) { $card in
                    TellHomeCardSection(card: $card, places: places, currency: currency, today: today) {
                        cards.removeAll { $0.id == card.id }
                    }
                }
                if !cards.isEmpty {
                    Section {
                        Button { cards.append(blankCard()) } label: { Label("Add another", systemImage: "plus") }
                    } footer: {
                        Text("Projects are saved as ideas. Change anything before you save.")
                    }
                }
            }
            .navigationTitle("Tell Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dictation.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : (included.count > 1 ? "Save \(included.count)" : "Save")) {
                        Task { await save() }
                    }
                    .bold()
                    .disabled(included.isEmpty || saving || dictation.isRecording)
                }
            }
            .alert("Couldn’t save", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
        .feedbackPage("Tell Home")
        .task { await load() }
        .onDisappear { dictation.stop() }
        .onChange(of: dictation.isRecording) { wasRecording, isRecording in
            // Listening ended (Stop, or the recognizer finished): keep the words and read them.
            if wasRecording && !isRecording {
                text = dictation.transcript
                read()
            }
        }
    }

    // MARK: Capture

    private var captureSection: some View {
        Section {
            VStack(spacing: 14) {
                Text("Say or type anything for your home — a job, a reminder or a project idea. Home sorts it out.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                micButton

                if dictation.isRecording {
                    Label("Listening… tap to stop.", systemImage: "waveform")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
                if let err = dictation.errorText {
                    Text(err).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: dictation.isRecording ? .constant(dictation.transcript) : $text)
                        .focused($editorFocused)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 96)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                        .accessibilityLabel("What to add")
                    if currentText.isEmpty {
                        Text("“We’re thinking of a new fence in 3 months, about $10k” or “change the HVAC filter every 3 months”")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

                if !dictation.isRecording && needsRead {
                    Button { editorFocused = false; read() } label: {
                        Label(cards.isEmpty ? "Sort it out" : "Read it again", systemImage: "sparkles")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !cards.isEmpty || !readText.isEmpty {
                    Text(summary)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var micButton: some View {
        Button { Task { await toggleListening() } } label: {
            VStack(spacing: 6) {
                Image(systemName: dictation.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(dictation.isRecording ? Color.red : Color.accentColor))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                Text(dictation.isRecording ? "Stop" : "Tap to talk")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.isRecording ? "Stop listening" : "Talk")
    }

    /// The words changed since the cards were read.
    private var needsRead: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t != readText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var summary: String {
        if cards.isEmpty { return "Nothing to add found — try saying what and when." }
        let todos = cards.filter { $0.kind == .todo }.count
        let projects = cards.count - todos
        var parts: [String] = []
        if todos > 0 { parts.append(todos == 1 ? "1 to-do" : "\(todos) to-dos") }
        if projects > 0 { parts.append(projects == 1 ? "1 project idea" : "\(projects) project ideas") }
        return "Found " + parts.joined(separator: " and ")
    }

    // MARK: Actions

    @MainActor
    private func load() async {
        let (p, idx) = await TIK.loadPlaces(env)
        propertyId = p?.id
        if let code = p?.currencyCode { currency = code }
        places = idx
        if !initialText.isEmpty { read() }
        else if startListening { await toggleListening() }
    }

    @MainActor
    private func toggleListening() async {
        if dictation.isRecording {
            dictation.stop()       // `onChange(of: isRecording)` keeps the words and reads them
        } else {
            editorFocused = false
            await dictation.start(prefix: text)
        }
    }

    private func read() {
        readText = text
        cards = SmartCapture.proposals(from: text, today: today, currency: currency).map(card(from:))
    }

    private func card(from p: SmartCapture.Proposal) -> Card {
        Card(kind: p.kind, title: p.title, amountText: ProjectInput.text(p.amount), hasDate: p.date != nil,
             date: p.date ?? defaultDate(p.kind), repeatRule: p.repeatRule, source: p.source)
    }

    private func blankCard() -> Card {
        Card(kind: .todo, title: "", amountText: "", hasDate: false, date: defaultDate(.todo), repeatRule: nil, source: "")
    }

    private func defaultDate(_ kind: SmartCapture.Kind) -> LocalDate {
        kind == .project ? today.adding(months: 1) : today
    }

    @MainActor
    private func save() async {
        guard let propertyId else { errorText = "Create your home first."; return }
        saving = true
        defer { saving = false }
        var saved: [UUID] = []
        for card in included {
            var amount: Money?
            if case .value(let m) = ProjectInput.money(card.amountText, currency: currency) { amount = m }
            let proposal = SmartCapture.Proposal(kind: card.kind, title: card.title, amount: amount,
                                                 date: card.hasDate ? card.date : nil,
                                                 repeatRule: card.kind == .todo ? card.repeatRule : nil, source: card.source)
            do {
                switch card.kind {
                case .todo:
                    _ = try await env.chores.create(proposal.choreDraft(propertyId: propertyId, scope: card.scope, today: today))
                case .project:
                    _ = try await env.projects.create(proposal.projectDraft(propertyId: propertyId, scope: card.scope))
                }
                saved.append(card.id)
            } catch {
                errorText = saved.isEmpty ? error.localizedDescription
                                          : "Saved \(saved.count); the rest failed: \(error.localizedDescription)"
                cards.removeAll { saved.contains($0.id) }
                return
            }
        }
        onSaved?(saved.count)
        dismiss()
    }
}

/// One editable proposal: kind, title, amount (projects), date, repeat (to-dos) and place.
private struct TellHomeCardSection: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var card: TellHomeSheet.Card
    let places: TIK.PlaceIndex
    let currency: String
    let today: LocalDate
    let onDelete: () -> Void

    /// Common repeats, plus whatever was heard if it isn't one of them.
    private var repeatOptions: [RepeatRule] {
        var options: [RepeatRule] = [
            RepeatRule(freq: .weekly, interval: 1), RepeatRule(freq: .weekly, interval: 2),
            RepeatRule(freq: .monthly, interval: 1), RepeatRule(freq: .monthly, interval: 3),
            RepeatRule(freq: .monthly, interval: 6), RepeatRule(freq: .monthly, interval: 12),
        ]
        if let r = card.repeatRule, !options.contains(r) { options.insert(r, at: 0) }
        return options
    }

    var body: some View {
        Section {
            Picker("Kind", selection: $card.kind) {
                Text("To-Do").tag(SmartCapture.Kind.todo)
                Text("Project idea").tag(SmartCapture.Kind.project)
            }
            .pickerStyle(.segmented)

            TextField(card.kind == .todo ? "To-do" : "Project", text: $card.title, axis: .vertical)
                .font(.body.weight(.semibold))

            if card.kind == .project {
                ProjectMoneyField(title: "Estimate", text: $card.amountText, currency: currency)
            }

            Toggle(card.kind == .project ? "Target date" : "Due date", isOn: $card.hasDate)
            if card.hasDate {
                DatePicker(card.kind == .project ? "Target" : "Due", selection: $card.date.scheduleDate(env.clock.calendar),
                           displayedComponents: .date)
            }

            if card.kind == .todo {
                Picker("Repeat", selection: $card.repeatRule) {
                    Text("Doesn’t repeat").tag(RepeatRule?.none)
                    ForEach(repeatOptions, id: \.self) { r in
                        Text(r.humanText).tag(RepeatRule?.some(r))
                    }
                }
            }

            TIK.PlacePicker(title: "Place", scope: $card.scope, places: places)
        } header: {
            HStack {
                Button { card.include.toggle() } label: {
                    Label(card.include ? "Will be added" : "Left out",
                          systemImage: card.include ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(card.include ? Color.accentColor : Color.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove")
            }
            .textCase(nil)
        } footer: {
            if !card.source.isEmpty {
                Text("From “\(card.source)”").lineLimit(2)
            }
        }
        .opacity(card.include ? 1 : 0.55)
    }
}

#Preview("Tell Home") {
    TellHomeSheet().environment(AppEnvironment.preview())
}

#Preview("Tell Home · fence and HVAC") {
    TellHomeSheet(initialText: "hey we're thinking of getting a new fence in 3 months & wanna spend 10k, could u put in that idea in\nadd task of changing hvac every 3 months")
        .environment(AppEnvironment.preview())
}
