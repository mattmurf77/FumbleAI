import Foundation
import HomeCore

/// Pure diff between the planner's desired set and the pending requests (LLD §9.3 "Diff"). Identifiers are
/// deterministic (`chore:<uuid>:<yyyy-MM-dd>`, `sys:…`, §9.4), so running it twice is a no-op.
public enum NotificationDiff {
    public struct Result: Hashable, Sendable {
        /// Pending ids to remove (not desired any more, or content changed).
        public var remove: [String]
        /// Desired requests to add (missing, or replacing a changed one).
        public var add: [PlannedNotification]
        public var isEmpty: Bool { remove.isEmpty && add.isEmpty }
    }

    /// True for identifiers this app owns. Requests with other ids are never touched.
    public static func isOwned(_ id: String) -> Bool {
        PlannedNotification.ownedPrefixes.contains { id.hasPrefix($0) }
    }

    public static func diff(desired: [PlannedNotification], pending: [PendingNotification]) -> Result {
        var desiredById: [String: PlannedNotification] = [:]
        for n in desired { desiredById[n.id] = n }          // last wins on (impossible) duplicates
        var remove: [String] = []
        var keep: Set<String> = []
        for p in pending where isOwned(p.id) {
            if let d = desiredById[p.id], p.contentHash == d.contentHash {
                keep.insert(p.id)
            } else {
                remove.append(p.id)
            }
        }
        let add = desired.filter { !keep.contains($0.id) }
        // Deduplicate adds by id preserving planner order.
        var seen: Set<String> = []
        let uniqueAdd = add.filter { seen.insert($0.id).inserted }
        return Result(remove: remove.sorted(), add: uniqueAdd)
    }

    /// Delivered notifications that no longer apply (LLD §9.3 step 4): the chore was completed/skipped past that
    /// occurrence, closed, paused, deleted or had its reminder switched off. Snooze and system ids are kept.
    public static func staleDelivered(_ delivered: [String], chores: [Chore], today: LocalDate) -> [String] {
        let byId = Dictionary(chores.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return delivered.filter { id in
            guard id.hasPrefix("chore:"), let choreId = PlannedNotification.choreUUID(fromIdentifier: id) else { return false }
            guard let c = byId[choreId], c.isOpen, c.remindEnabled, let next = c.nextDueOn else { return true }
            let suffix = id.split(separator: ":").last.map(String.init) ?? ""
            if suffix == "overdue" { return !(next < today) }
            guard let day = LocalDate(string: suffix) else { return false }
            // An occurrence before the current due date has been satisfied (done / skipped / rescheduled).
            return day < next
        }.sorted()
    }
}
