import SwiftUI
import HomeCore
import HomeCoreTesting
#if canImport(UIKit)
import UIKit
#endif

/// Capture many to-dos at once: talk ("clean gutters, replace the furnace filter and call the plumber"), paste a list
/// copied from Notes or Messages, or type. The text is split into items (`ListCapture`) that you review — edit, untick,
/// pick when and where — before they're added. Self-contained (own `NavigationStack`); present it in a sheet.
struct QuickCaptureSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable, Hashable {
        let id = UUID()
        var title: String
        var include = true
    }

    private enum When: String, CaseIterable, Identifiable {
        case noDate, today, weekend, pick
        var id: String { rawValue }
        var title: String {
            switch self {
            case .noDate: return "No date"; case .today: return "Today"
            case .weekend: return "This weekend"; case .pick: return "Pick a date"
            }
        }
    }

    let initialText: String
    let initialScope: Scope?
    let startListening: Bool
    let onAdded: ((Int) -> Void)?

    @State private var text: String
    @State private var items: [Item] = []
    @State private var reviewing = false
    @State private var when: When = .noDate
    @State private var pickedDate = Date()
    @State private var scope: Scope = .property
    @State private var places = TIK.PlaceIndex()
    @State private var propertyId: UUID?
    @State private var dictation = SpeechDictation()
    @State private var saving = false
    @State private var errorText: String?
    @FocusState private var editorFocused: Bool

    init(initialText: String = "", scope: Scope? = nil, startListening: Bool = false, onAdded: ((Int) -> Void)? = nil) {
        self.initialText = initialText
        self.initialScope = scope
        self.startListening = startListening
        self.onAdded = onAdded
        _text = State(initialValue: initialText)
    }

    private var included: [Item] { items.filter { $0.include && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty } }

    var body: some View {
        NavigationStack {
            Group {
                if reviewing { review } else { capture }
            }
            .navigationTitle(reviewing ? "Review to-dos" : "Quick add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(reviewing ? "Back" : "Cancel") {
                        if reviewing { reviewing = false } else { dictation.stop(); dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if reviewing {
                        Button(saving ? "Adding…" : "Add \(included.count)") { Task { await save() } }
                            .disabled(included.isEmpty || saving)
                    } else {
                        Button("Next") { goToReview() }
                            .disabled(ListCapture.items(from: currentText).isEmpty)
                    }
                }
            }
            .alert("Couldn’t add the to-dos", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
        .feedbackPage("Quick add to-dos")
        .task { await load() }
        .onDisappear { dictation.stop() }
    }

    /// The editor text, or the live transcript while listening.
    private var currentText: String { dictation.isRecording ? dictation.transcript : text }

    // MARK: Capture

    private var capture: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Say or paste a list. Separate items with commas, “and then”, or new lines — you’ll check them before they’re added.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("Tip: in Notes, Mail or Photos, tap Share → Home Blueprint to send a list, a receipt or an email here.",
                  systemImage: "square.and.arrow.up")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: dictation.isRecording ? .constant(dictation.transcript) : $text)
                    .focused($editorFocused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                if currentText.isEmpty {
                    Text("Clean gutters, replace furnace filter and call the plumber")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 12) {
                Button { Task { await toggleListening() } } label: {
                    Label(dictation.isRecording ? "Stop" : "Talk", systemImage: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(dictation.isRecording ? .red : .accentColor)

                Button { paste() } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .disabled(dictation.isRecording)
            }

            if dictation.isRecording {
                Label("Listening… tap Stop when you’re done.", systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            if let err = dictation.errorText {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            let count = ListCapture.items(from: currentText).count
            if count > 0 {
                Text(count == 1 ? "1 to-do found" : "\(count) to-dos found")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: Review

    private var review: some View {
        Form {
            Section {
                ForEach($items) { $item in
                    HStack(spacing: 10) {
                        Button { item.include.toggle() } label: {
                            Image(systemName: item.include ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(item.include ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.include ? "Included" : "Left out")
                        TextField("To-do", text: $item.title, axis: .vertical)
                            .foregroundStyle(item.include ? .primary : .secondary)
                    }
                }
                .onDelete { items.remove(atOffsets: $0) }
                Button { items.append(Item(title: "")) } label: { Label("Add another", systemImage: "plus") }
            } header: {
                Text("\(included.count) of \(items.count) will be added")
            } footer: {
                Text("Tap a circle to leave an item out, or swipe to delete it.")
            }

            Section("When") {
                Picker("Due", selection: $when) {
                    ForEach(When.allCases) { Text($0.title).tag($0) }
                }
                if when == .pick {
                    DatePicker("Date", selection: $pickedDate, displayedComponents: .date)
                }
            }

            Section("Where") {
                TIK.PlacePicker(title: "Place", scope: $scope, places: places)
            }
        }
    }

    // MARK: Actions

    @MainActor
    private func load() async {
        let (p, idx) = await TIK.loadPlaces(env)
        propertyId = p?.id
        places = idx
        if let initialScope { scope = initialScope }
        if startListening && text.isEmpty { await toggleListening() }
        else if !initialText.isEmpty && !ListCapture.items(from: initialText).isEmpty { goToReview() }
    }

    @MainActor
    private func toggleListening() async {
        if dictation.isRecording {
            dictation.stop()
            text = dictation.transcript
        } else {
            editorFocused = false
            await dictation.start(prefix: text)
        }
    }

    private func paste() {
        #if canImport(UIKit)
        guard let clip = UIPasteboard.general.string, !clip.isEmpty else { return }
        text = text.isEmpty ? clip : text + "\n" + clip
        #endif
    }

    private func goToReview() {
        if dictation.isRecording {
            dictation.stop()
            text = dictation.transcript
        }
        items = ListCapture.items(from: text).map { Item(title: $0) }
        reviewing = true
    }

    private func dueDate() -> LocalDate {
        let today = env.clock.today
        switch when {
        case .noDate, .today: return today
        case .weekend:
            // Next Saturday (today when it is Saturday).
            let weekday = env.clock.calendar.component(.weekday, from: env.clock.now)   // 1 = Sunday … 7 = Saturday
            return today.adding(days: (7 - weekday) % 7)
        case .pick: return LocalDate(pickedDate, calendar: env.clock.calendar)
        }
    }

    @MainActor
    private func save() async {
        guard let propertyId else { errorText = "Create your home first."; return }
        saving = true
        defer { saving = false }
        let start = dueDate()
        var added = 0
        for item in included {
            let title = String(item.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ListCapture.maxTitleLength))
            let draft = ChoreDraft(propertyId: propertyId, scope: scope, title: title, startOn: start, noDueDate: when == .noDate)
            do {
                _ = try await env.chores.create(draft)
                added += 1
            } catch {
                errorText = added == 0 ? error.localizedDescription : "Added \(added); the rest failed: \(error.localizedDescription)"
                items.removeAll { included.prefix(added).map(\.id).contains($0.id) }
                return
            }
        }
        onAdded?(added)
        dismiss()
    }
}

#Preview("Quick add") {
    QuickCaptureSheet().environment(AppEnvironment.preview())
}

#Preview("Quick add · from Notes") {
    QuickCaptureSheet(initialText: "Weekend jobs:\n- [ ] Clean gutters\n- [ ] Seal the deck\n- Buy mulch")
        .environment(AppEnvironment.preview())
}
