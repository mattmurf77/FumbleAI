import SwiftUI
import HomeCore

/// Dynamic template fields (spec 06 FR-THG-10/11) rendered from a HomeCore `ThingTemplate` schema: bulb base /
/// wattage / color temperature, filter size / MERV, fuel, capacity… All optional; clearing a field removes the key.
struct TemplateFields: View {
    let template: ThingTemplate
    @Binding var attributes: [String: JSONValue]
    var calendar: Calendar = .current
    var today: LocalDate = LocalDate(Date(), calendar: .current)

    var body: some View {
        ForEach(template.fields, id: \.key) { field in
            row(field)
        }
    }

    @ViewBuilder
    private func row(_ field: ThingTemplate.Field) -> some View {
        switch field.kind {
        case .bool:
            Toggle(field.label, isOn: Binding(
                get: { attributes[field.key]?.boolValue ?? false },
                set: { attributes[field.key] = .bool($0) }))
        case .choice:
            let current = attributes[field.key]?.displayText ?? ""
            let choices = field.choices ?? []
            Picker(field.label, selection: Binding(
                get: { current },
                set: { attributes[field.key] = $0.isEmpty ? nil : .string($0) })) {
                Text("Not set").tag("")
                ForEach(choices, id: \.self) { Text($0).tag($0) }
                if !current.isEmpty && !choices.contains(current) { Text(current).tag(current) }
            }
        case .date:
            TIK.OptionalDateRow(title: field.label, date: Binding(
                get: { attributes[field.key]?.stringValue.flatMap { LocalDate(string: $0) } },
                set: { attributes[field.key] = $0.map { .string($0.description) } }),
                calendar: calendar, defaultDate: today)
        case .text, .number:
            AttributeTextRow(field: field, unit: TIK.extra(for: template.key).fieldUnits[field.key],
                             integer: TIK.extra(for: template.key).integerFields.contains(field.key),
                             value: Binding(get: { attributes[field.key] }, set: { attributes[field.key] = $0 }))
        }
    }
}

/// Text/number attribute row with its own text state, so partially typed numbers ("1.") aren't reformatted.
private struct AttributeTextRow: View {
    let field: ThingTemplate.Field
    let unit: String?
    let integer: Bool
    @Binding var value: JSONValue?
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        HStack {
            Text(field.label)
            Spacer(minLength: 12)
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .keyboardType(field.kind == .number ? (integer ? .numberPad : .decimalPad) : .default)
                .autocorrectionDisabled()
                .textInputAutocapitalization(field.kind == .text ? .sentences : .never)
            if let unit { Text(unit).foregroundStyle(.secondary) }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = TIK.attributeText(value, kind: field.kind)
        }
        .onChange(of: text) { _, new in
            value = TIK.attributeValue(fromText: new, kind: field.kind)
        }
    }

    private var placeholder: String {
        switch field.key {
        case "filterSize": return "16x25x1"
        case "merv": return "1–16"
        case "wattage": return "60"
        default: return field.kind == .number ? "0" : "Optional"
        }
    }
}

/// Template chooser: catalog grouped by category + "Custom" (no template).
struct TemplatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selectedKey: String?
    let onPick: (ThingTemplate?) -> Void
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(nil); dismiss()
                    } label: {
                        row(title: "Custom", subtitle: "No template fields", symbol: "shippingbox", selected: selectedKey == nil)
                    }
                }
                ForEach(TIK.templatesByCategory(filtered).map { TemplateGroup(category: $0.0, templates: $0.1) }) { group in
                    Section(TIK.categoryTitle(group.category)) {
                        ForEach(group.templates) { t in
                            Button {
                                onPick(t); dismiss()
                            } label: {
                                row(title: t.name, subtitle: t.fields.map(\.label).prefix(3).joined(separator: ", "),
                                    symbol: t.symbol, selected: selectedKey == t.key)
                            }
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: "Search templates")
            .navigationTitle("Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var filtered: [ThingTemplate] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ThingTemplate.catalog }
        return ThingTemplate.catalog.filter { $0.name.lowercased().contains(q) || $0.key.contains(q) }
    }

    private func row(title: String, subtitle: String, symbol: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }
}

private struct TemplateGroup: Identifiable {
    let category: Thing.Category
    let templates: [ThingTemplate]
    var id: String { category.rawValue }
}

#Preview("Light fixture fields") {
    struct Host: View {
        @State var attrs: [String: JSONValue] = ["bulbBase": "E26", "colorTemp": "2700K"]
        var body: some View {
            Form { TemplateFields(template: ThingTemplate.find("light_fixture")!, attributes: $attrs) }
        }
    }
    return Host().environment(AppEnvironment.preview())
}

#Preview("Template picker") {
    TemplatePickerSheet(selectedKey: "hvac_furnace") { _ in }
}
