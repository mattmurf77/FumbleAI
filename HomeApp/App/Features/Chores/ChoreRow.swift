import SwiftUI
import HomeCore
import HomeCoreTesting

/// One chore in a list: completion circle, title, due line (red when overdue), place and assignee.
/// Used by `ToDosListView` and room / whole-house sheets.
struct ChoreRow: View {
    let chore: Chore
    let today: LocalDate
    /// "Kitchen" / "Whole house" (nil hides it, e.g. inside a room sheet).
    var place: String?
    var assignee: String?
    /// Nil hides the circle.
    var onComplete: (() -> Void)?

    private var overdue: Bool { chore.isOverdue(today: today) }

    var body: some View {
        HStack(spacing: 12) {
            if let onComplete {
                Button(action: onComplete) {
                    Image(systemName: "circle")
                        .font(.title2)
                        .foregroundStyle(overdue ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(chore.title) done")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chore.title).font(.body.weight(.medium)).lineLimit(2)
                    if chore.isRecurring {
                        Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Repeats")
                    }
                    if chore.remindEnabled && !chore.isPaused {
                        Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Reminder on")
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(overdue ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if overdue {
                Text("!").font(.headline).foregroundStyle(.red).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .opacity(chore.isPaused ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        [ScheduleFormat.due(chore, today: today), place, assignee].compactMap { $0 }.joined(separator: " · ")
    }
}

private enum ChoreRowPreviewData {
    static let today = LocalDate(2026, 9, 29)
    static var chores: [Chore] {
        SampleHome.snapshot(today: today).chores.values.sorted { ($0.nextDueOn ?? today) < ($1.nextDueOn ?? today) }
    }
}

#Preview {
    List {
        ForEach(ChoreRowPreviewData.chores) { c in
            ChoreRow(chore: c, today: ChoreRowPreviewData.today, place: "Kitchen", assignee: "Matt", onComplete: {})
        }
    }
}
