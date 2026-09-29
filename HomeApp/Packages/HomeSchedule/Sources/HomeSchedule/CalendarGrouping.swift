import Foundation
import HomeCore

/// Pure helpers for the calendar picker (FR-CHR-52/53).
public enum CalendarSourceNaming {
    /// "iCloud", "Gmail – you@gmail.com", "Exchange"… Google accounts added in iOS Settings show up as CalDAV
    /// sources titled with the address (or "Gmail").
    public static func displayTitle(sourceTitle t: String) -> String {
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Other" }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("gmail –") || lower.hasPrefix("gmail -") { return trimmed }
        if lower.hasSuffix("@gmail.com") || lower.hasSuffix("@googlemail.com") { return "Gmail – \(trimmed)" }
        return trimmed
    }

    public static func isGoogle(_ sourceTitle: String) -> Bool {
        let l = sourceTitle.lowercased()
        return l.contains("gmail") || l.contains("google")
    }

    public static func isICloud(_ sourceTitle: String) -> Bool { sourceTitle.lowercased().contains("icloud") }
}

/// A picker section: one account.
public struct CalendarGroup: Hashable, Sendable, Identifiable {
    public var sourceTitle: String
    public var calendars: [CalendarInfo]
    public var id: String { sourceTitle }
    public var isGoogle: Bool { CalendarSourceNaming.isGoogle(sourceTitle) }
    public init(sourceTitle: String, calendars: [CalendarInfo]) { self.sourceTitle = sourceTitle; self.calendars = calendars }

    /// Groups by source: iCloud first, then On My iPhone, then the rest alphabetically; calendars by title.
    public static func group(_ calendars: [CalendarInfo]) -> [CalendarGroup] {
        let bySource = Dictionary(grouping: calendars, by: \.sourceTitle)
        func rank(_ s: String) -> Int {
            if CalendarSourceNaming.isICloud(s) { return 0 }
            if s == "On My iPhone" { return 1 }
            return 2
        }
        return bySource.keys.sorted { (rank($0), $0) < (rank($1), $1) }.map { key in
            CalendarGroup(sourceTitle: key, calendars: (bySource[key] ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }

    /// The suggested "Home" calendar, if one already exists (iCloud preferred).
    public static func existingHome(in calendars: [CalendarInfo]) -> CalendarInfo? {
        let homes = calendars.filter { $0.title.caseInsensitiveCompare(CalendarSync.homeCalendarTitle) == .orderedSame }
        return homes.first { CalendarSourceNaming.isICloud($0.sourceTitle) } ?? homes.first
    }
}
