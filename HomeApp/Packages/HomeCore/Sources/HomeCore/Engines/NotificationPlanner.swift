import Foundation

/// A desired local notification. The scheduler (HomeSchedule) diffs these against pending requests by `id`
/// and `contentHash` (stored in `userInfo["h"]`). LLD §9.3–9.4.
public struct PlannedNotification: Hashable, Sendable {
    /// "chore:<uuid>:<yyyy-MM-dd>" | "chore:<uuid>:overdue" | "sys:sentinel" | "sys:pantry-digest" | "sys:snooze-<n>"
    public var id: String
    /// year, month, day, hour, minute — floating (no time zone). Use `UNCalendarNotificationTrigger(repeats: false)`.
    public var fire: DateComponents
    public var title: String
    public var body: String
    /// "CHORE_DUE" (actions DONE, SNOOZE_1H) or "SYSTEM".
    public var categoryId: String
    /// "chore:<uuid>" (groups in Notification Center) or "sys".
    public var threadId: String
    /// Stable across launches (FNV-1a of title+body+fire). Never use `hashValue` — it is per-process seeded.
    public var contentHash: Int
    /// Chore this notification is for (nil for system ones).
    public var choreId: UUID?
    /// Deep link for the body tap.
    public var deepLink: URL?

    public init(id: String, fire: DateComponents, title: String, body: String, categoryId: String, threadId: String,
                choreId: UUID? = nil, deepLink: URL? = nil) {
        self.id = id; self.fire = fire; self.title = title; self.body = body; self.categoryId = categoryId
        self.threadId = threadId; self.choreId = choreId; self.deepLink = deepLink
        self.contentHash = PlannedNotification.stableHash("\(title)|\(body)|\(fire.year ?? 0)-\(fire.month ?? 0)-\(fire.day ?? 0) \(fire.hour ?? 0):\(fire.minute ?? 0)")
    }

    public static let choreCategory = "CHORE_DUE"
    public static let systemCategory = "SYSTEM"
    public static let doneAction = "DONE"
    public static let snoozeAction = "SNOOZE_1H"
    public static let sentinelId = "sys:sentinel"
    public static let pantryDigestId = "sys:pantry-digest"
    /// Identifiers this app owns (the scheduler only touches these prefixes).
    public static let ownedPrefixes = ["chore:", "sys:"]

    public static func choreId(_ id: UUID, due: LocalDate) -> String { "chore:\(id.uuidString.lowercased()):\(due)" }
    public static func overdueId(_ id: UUID) -> String { "chore:\(id.uuidString.lowercased()):overdue" }

    /// Parses the chore UUID out of a "chore:<uuid>:…" identifier.
    public static func choreUUID(fromIdentifier s: String) -> UUID? {
        let parts = s.split(separator: ":")
        guard parts.count >= 2, parts[0] == "chore" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    /// FNV-1a 64-bit, folded to Int.
    public static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h)
    }
}

/// Planner input for one chore (value snapshot; no DB types).
public struct ChoreReminderInput: Hashable, Sendable {
    public var choreId: UUID
    public var title: String
    /// "Kitchen" / "Whole house" (notification body).
    public var location: String?
    public var nextDueOn: LocalDate?
    public var dueMinutes: MinuteOfDay?
    public var remindOffsetMin: Int
    public var rule: RepeatRule?
    public var startOn: LocalDate
    public var remindEnabled: Bool
    public var isPaused: Bool
    public var isClosed: Bool
    public var isDeleted: Bool

    public init(choreId: UUID, title: String, location: String? = nil, nextDueOn: LocalDate?, dueMinutes: MinuteOfDay? = nil,
                remindOffsetMin: Int = 0, rule: RepeatRule? = nil, startOn: LocalDate, remindEnabled: Bool = true,
                isPaused: Bool = false, isClosed: Bool = false, isDeleted: Bool = false) {
        self.choreId = choreId; self.title = title; self.location = location; self.nextDueOn = nextDueOn
        self.dueMinutes = dueMinutes; self.remindOffsetMin = remindOffsetMin; self.rule = rule; self.startOn = startOn
        self.remindEnabled = remindEnabled; self.isPaused = isPaused; self.isClosed = isClosed; self.isDeleted = isDeleted
    }

    public init(chore c: Chore, location: String? = nil) {
        self.init(choreId: c.id, title: c.title, location: location, nextDueOn: c.nextDueOn, dueMinutes: c.dueMinutes,
                  remindOffsetMin: c.remindOffsetMin, rule: c.repeatRule, startOn: c.startOn, remindEnabled: c.remindEnabled,
                  isPaused: c.isPaused, isClosed: c.closedAt != nil, isDeleted: c.deletedAt != nil)
    }

    var isEligible: Bool { remindEnabled && !isPaused && !isClosed && !isDeleted && nextDueOn != nil }
}

/// An active "In 1 hour" snooze (local `notification_snooze` table).
public struct Snooze: Hashable, Sendable {
    public var id: String
    public var choreId: UUID
    public var title: String
    public var fireAt: Date
    public var createdAt: Date
    public init(id: String = UUID().uuidString, choreId: UUID, title: String, fireAt: Date, createdAt: Date = Date()) {
        self.id = id; self.choreId = choreId; self.title = title; self.fireAt = fireAt; self.createdAt = createdAt
    }
}

/// Opt-in pantry expiry digest (HLD §9-9).
public struct PantryDigest: Hashable, Sendable {
    /// Items expiring within 3 days.
    public var expiringCount: Int
    public init(expiringCount: Int) { self.expiringCount = expiringCount }
}

/// Pure planner for the 64-request iOS limit: 60 chore slots + 4 reserved (sentinel, pantry digest, 2 snoozes).
public struct NotificationPlanner: Sendable {
    public static let choreSlots = 60, horizonDays = 14, perChoreMax = 14, maxSnoozes = 2, iOSLimit = 64

    public var allDayMinutes: MinuteOfDay
    public init(allDayMinutes: MinuteOfDay = Chore.defaultAllDayMinutes) { self.allDayMinutes = allDayMinutes }

    private struct Candidate {
        var choreId: UUID
        var index: Int
        var fireDate: Date
        var note: PlannedNotification
    }

    public func plan(chores: [ChoreReminderInput], snoozes: [Snooze], pantryDigest: PantryDigest?,
                     now: Date, calendar: Calendar, engine: RecurrenceEngine) -> [PlannedNotification] {
        let today = LocalDate(now, calendar: calendar)
        guard let horizon = calendar.date(byAdding: .day, value: NotificationPlanner.horizonDays, to: now) else { return [] }
        var candidates: [Candidate] = []

        for c in chores where c.isEligible {
            guard let due = c.nextDueOn else { continue }
            let minutes = (c.dueMinutes ?? allDayMinutes) - c.remindOffsetMin
            var index = 0
            var perChore = 0

            func fireFor(_ day: LocalDate) -> (DateComponents, Date)? {
                let dayShift = Int((Double(minutes) / 1440).rounded(.down))
                let m = minutes - dayShift * 1440
                let d = day.adding(days: dayShift)
                guard let date = d.date(atMinutes: m, calendar: calendar) else { return nil }
                return (d.components(atMinutes: m), date)
            }

            if due < today {
                // Overdue nudge at today's fire time if still ahead, otherwise tomorrow's.
                let tod = ((minutes % 1440) + 1440) % 1440
                var day = today
                if let d = day.date(atMinutes: tod, calendar: calendar), d <= now { day = today.adding(days: 1) }
                if let date = day.date(atMinutes: tod, calendar: calendar), date <= horizon {
                    let n = PlannedNotification(id: PlannedNotification.overdueId(c.choreId), fire: day.components(atMinutes: tod),
                                                title: "Overdue: \(c.title)", body: c.location ?? "Tap to mark it done",
                                                categoryId: PlannedNotification.choreCategory,
                                                threadId: "chore:\(c.choreId.uuidString.lowercased())",
                                                choreId: c.choreId, deepLink: ItemRef.chore(c.choreId).deepLink)
                    candidates.append(Candidate(choreId: c.choreId, index: index, fireDate: date, note: n))
                    index += 1; perChore += 1
                }
            } else if let (comps, date) = fireFor(due), date > now, date <= horizon {
                candidates.append(Candidate(choreId: c.choreId, index: index, fireDate: date,
                                            note: note(for: c, due: due, fire: comps, today: today)))
                index += 1; perChore += 1
            }

            // Schedule-anchored: the following occurrences within the horizon.
            if let rule = c.rule, rule.anchor == .schedule {
                let from = max(due, today).adding(days: 1)
                for occ in engine.occurrences(of: rule, start: c.startOn, from: from) {
                    guard perChore < NotificationPlanner.perChoreMax, let (comps, date) = fireFor(occ) else { break }
                    if date > horizon { break }
                    if date <= now { continue }
                    candidates.append(Candidate(choreId: c.choreId, index: index, fireDate: date,
                                                note: note(for: c, due: occ, fire: comps, today: today)))
                    index += 1; perChore += 1
                }
            }
        }

        // Fairness: every chore's next reminder before anyone's second.
        candidates.sort { ($0.index, $0.fireDate, $0.note.id) < ($1.index, $1.fireDate, $1.note.id) }
        let kept = Array(candidates.prefix(NotificationPlanner.choreSlots))
        let dropped = candidates.dropFirst(NotificationPlanner.choreSlots)
        var result = kept.sorted { ($0.fireDate, $0.note.id) < ($1.fireDate, $1.note.id) }.map(\.note)

        if let earliest = dropped.map(\.fireDate).min() {
            let at = earliest.addingTimeInterval(-60)
            result.append(PlannedNotification(id: PlannedNotification.sentinelId, fire: floating(at, calendar),
                                              title: "Home", body: "Open Home to keep your reminders coming.",
                                              categoryId: PlannedNotification.systemCategory, threadId: "sys"))
        }

        if let digest = pantryDigest, digest.expiringCount > 0 {
            let tomorrow = today.adding(days: 1)
            result.append(PlannedNotification(id: PlannedNotification.pantryDigestId, fire: tomorrow.components(atMinutes: 540),
                                              title: "Pantry", body: "\(digest.expiringCount) item\(digest.expiringCount == 1 ? "" : "s") expire soon",
                                              categoryId: PlannedNotification.systemCategory, threadId: "sys"))
        }

        let activeSnoozes = snoozes.filter { $0.fireAt > now }.sorted { $0.createdAt > $1.createdAt }.prefix(NotificationPlanner.maxSnoozes)
        for (i, s) in activeSnoozes.sorted(by: { $0.createdAt < $1.createdAt }).enumerated() {
            result.append(PlannedNotification(id: "sys:snooze-\(i + 1)", fire: floating(s.fireAt, calendar), title: s.title,
                                              body: "Snoozed reminder", categoryId: PlannedNotification.choreCategory,
                                              threadId: "chore:\(s.choreId.uuidString.lowercased())",
                                              choreId: s.choreId, deepLink: ItemRef.chore(s.choreId).deepLink))
        }
        return result
    }

    private func note(for c: ChoreReminderInput, due: LocalDate, fire: DateComponents, today: LocalDate) -> PlannedNotification {
        let fireDay = LocalDate(year: fire.year ?? due.year, month: fire.month ?? due.month, day: fire.day ?? due.day)
        let when: String
        switch fireDay.days(until: due) {
        case 0: when = "Due today"
        case 1: when = "Due tomorrow"
        default: when = "Due \(NotificationPlanner.shortDate(due))"
        }
        let body = [c.location, when].compactMap { $0 }.joined(separator: " · ")
        return PlannedNotification(id: PlannedNotification.choreId(c.choreId, due: due), fire: fire, title: c.title, body: body,
                                   categoryId: PlannedNotification.choreCategory,
                                   threadId: "chore:\(c.choreId.uuidString.lowercased())",
                                   choreId: c.choreId, deepLink: ItemRef.chore(c.choreId).deepLink)
    }

    static func shortDate(_ d: LocalDate) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[d.month - 1]) \(d.day)"
    }

    private func floating(_ date: Date, _ calendar: Calendar) -> DateComponents {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute)
    }

    /// App badge: chores due today plus overdue.
    public static func badgeCount(chores: [Chore], today: LocalDate) -> Int {
        chores.filter { $0.isOpen && ($0.nextDueOn.map { $0 <= today } ?? false) }.count
    }
}
