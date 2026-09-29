import SwiftUI
import HomeCore
import HomeCoreTesting

/// Repeat rule editor (FR-CHR-10…14): none / daily / weekly (weekdays) / every N days / monthly (day or last day),
/// anchor ("On schedule" / "After completion"), optional end date, plus a plain-language preview and the next 3 dates.
/// Put it inside a `Form`; it contributes rows to the current section.
struct RepeatRulePicker: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var rule: RepeatRule?
    let startOn: LocalDate

    private enum Kind: String, CaseIterable, Identifiable {
        case never, daily, weekly, everyNDays, monthly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .never: return "Never"; case .daily: return "Daily"; case .weekly: return "Weekly"
            case .everyNDays: return "Every N days"; case .monthly: return "Monthly / yearly"
            }
        }
    }

    private var kind: Binding<Kind> {
        Binding {
            guard let rule else { return .never }
            switch rule.freq { case .daily: return .daily; case .weekly: return .weekly; case .everyNDays: return .everyNDays; case .monthly: return .monthly }
        } set: { k in
            switch k {
            case .never: rule = nil
            case .daily: rule = RepeatRule(freq: .daily, until: rule?.until)
            case .weekly: rule = RepeatRule(freq: .weekly, weekdays: [startOn.weekday], until: rule?.until)
            case .everyNDays: rule = RepeatRule(freq: .everyNDays, interval: max(rule?.interval ?? 30, 2), until: rule?.until)
            case .monthly: rule = RepeatRule(freq: .monthly, dayOfMonth: startOn.day, until: rule?.until)
            }
        }
    }

    private func field<T>(_ kp: WritableKeyPath<RepeatRule, T>, _ fallback: T) -> Binding<T> {
        Binding { rule?[keyPath: kp] ?? fallback } set: { v in
            guard var r = rule else { return }
            r[keyPath: kp] = v
            rule = r
        }
    }

    var body: some View {
        Picker("Repeat", selection: kind) {
            ForEach(Kind.allCases) { Text($0.label).tag($0) }
        }
        if let current = rule {
            switch current.freq {
            case .daily:
                Stepper(current.interval == 1 ? "Every day" : "Every \(current.interval) days",
                        value: field(\.interval, 1), in: 1...365)
            case .everyNDays:
                Stepper("Every \(current.interval) days", value: field(\.interval, 30), in: 1...730)
            case .weekly:
                Stepper(current.interval == 1 ? "Every week" : "Every \(current.interval) weeks",
                        value: field(\.interval, 1), in: 1...52)
                WeekdayChips(selection: Binding {
                    Set(current.weekdays ?? [startOn.weekday])
                } set: { days in
                    var r = current
                    r.weekdays = days.isEmpty ? [startOn.weekday] : days.sorted()
                    rule = r
                })
            case .monthly:
                Stepper(monthlyIntervalLabel(current.interval), value: field(\.interval, 1), in: 1...24)
                Picker("On day", selection: Binding { current.dayOfMonth ?? startOn.day } set: { d in
                    var r = current; r.dayOfMonth = d; rule = r
                }) {
                    ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                    Text("Last day").tag(-1)
                }
            }
            Picker("Next due", selection: field(\.anchor, .schedule)) {
                Text("On schedule").tag(RepeatRule.Anchor.schedule)
                Text("After completion").tag(RepeatRule.Anchor.completion)
            }
            .pickerStyle(.segmented)
            Toggle("End date", isOn: Binding { current.until != nil } set: { on in
                var r = current
                r.until = on ? (current.until ?? startOn.adding(months: 12)) : nil
                rule = r
            })
            if let until = current.until {
                let untilBinding = Binding<LocalDate>(get: { until }, set: { d in
                    var r = current; r.until = max(d, startOn); rule = r
                })
                DatePicker("Ends on", selection: untilBinding.scheduleDate(env.clock.calendar), displayedComponents: .date)
            }
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(rule?.humanText ?? "Doesn't repeat")
            let next = nextDates
            if !next.isEmpty {
                Text("Next: " + next.map { ScheduleFormat.day($0) }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    private func monthlyIntervalLabel(_ n: Int) -> String {
        switch n { case 1: return "Every month"; case 12: return "Every year"; default: return "Every \(n) months" }
    }

    /// FR-CHR-14: the next 3 due dates (completion-anchored assumes each is done on its due day).
    private var nextDates: [LocalDate] {
        let engine = env.recurrence
        guard let first = engine.firstDue(rule: rule, start: startOn) else { return [] }
        guard let rule else { return [first] }
        var out = [first]
        while out.count < 3, let n = engine.nextDue(rule: rule, start: startOn, currentDue: out.last!, actedOn: out.last!) {
            out.append(n)
        }
        return out
    }
}

/// Seven toggle chips (Sun…Sat; order follows the locale's first weekday).
struct WeekdayChips: View {
    @Binding var selection: Set<Int>
    private let symbols = ["S", "M", "T", "W", "T", "F", "S"]
    private let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        let first = Calendar.current.firstWeekday
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                let day = (first - 1 + i) % 7 + 1
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(symbols[day - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

private struct RepeatRulePickerPreview: View {
    @State var rule: RepeatRule? = .weekly([3, 6])
    var body: some View {
        NavigationStack { Form { Section("Schedule") { RepeatRulePicker(rule: $rule, startOn: LocalDate(2026, 9, 29)) } } }
    }
}

#Preview {
    RepeatRulePickerPreview().environment(AppEnvironment.preview())
}
