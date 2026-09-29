import Foundation
import GRDB
import HomeCore
import PlanKit

/// CSV export (LLD §13, spec 09 FR-SES-20..25): 11 CSVs + README.txt (+ optional attachments/) in a temp folder,
/// zipped with `NSFileCoordinator(.forUploading)` on Apple platforms. Where that API is unavailable (Linux) the
/// folder URL is returned instead of a zip.
public struct CSVExporter: ExportService {
    public let db: AppDatabase
    public let files: AttachmentFileStore
    public let outputDirectory: URL
    public init(_ db: AppDatabase, files: AttachmentFileStore, outputDirectory: URL = FileManager.default.temporaryDirectory) {
        self.db = db; self.files = files; self.outputDirectory = outputDirectory
    }

    public static let fileNames = ["spaces.csv", "chores.csv", "chore_completions.csv", "projects.csv", "cost_line_items.csv", "things.csv",
                                   "inventory.csv", "measurements.csv", "storage_spots.csv", "people.csv", "budget_summary.csv"]

    public func exportCSV(property: UUID, options: ExportOptions) async throws -> URL {
        let today = db.clock.today
        let name = "Home-Export-\(today)"
        let work = outputDirectory.appendingPathComponent("home-export-\(UUID().uuidString.lowercased())", isDirectory: true)
        let folder = work.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tables = try await db.read { d in try Self.tables(d, property: property) }
        for (file, (header, rows)) in tables { try CSV.file(header: header, rows: rows).write(to: folder.appendingPathComponent(file)) }
        try Data(Self.readme.utf8).write(to: folder.appendingPathComponent("README.txt"))
        if options.includeAttachments {
            let atts = try await db.read { d in try Attachment.fetchAll(d, where: "property_id = ?", [property.db]) }
            let dir = folder.appendingPathComponent("attachments", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for a in atts where files.exists(a) {
                let dest = dir.appendingPathComponent("\(a.ownerType.rawValue)-\(a.ownerId.db)-\(a.id.db).\(a.fileExt)")
                try? FileManager.default.copyItem(at: files.url(for: a), to: dest)
            }
        }
        return try Self.zip(folder: folder, name: name, into: work)
    }

    /// Zips `folder` into `<work>/<name>.zip` (Apple platforms), else returns the folder.
    static func zip(folder: URL, name: String, into work: URL) throws -> URL {
        #if canImport(Darwin)
        var zipURL: URL?
        var copyError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { tmp in
            let dest = work.appendingPathComponent("\(name).zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: tmp, to: dest)
                zipURL = dest
            } catch { copyError = error }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        return zipURL ?? folder
        #else
        return folder
        #endif
    }

    static let readme = """
        Home export\r
        \r
        One CSV per record kind (UTF-8 with BOM, RFC 4180, CRLF). The first row holds column names.\r
        Dates: YYYY-MM-DD (local dates) and YYYY-MM-DDTHH:MM:SSZ (instants, UTC).\r
        Money: decimal major units (e.g. 4612.00) with a currency column.\r
        Lengths: inches with 2 decimals; *_display columns use your chosen units.\r
        IDs are included so a later version can re-import the data. Deleted items are not exported.\r
        Files: spaces, chores, chore_completions, projects, cost_line_items, things, inventory, measurements,\r
        storage_spots, people, budget_summary (+ attachments/ when "Include photos and receipts" is on).\r

        """

    static func tables(_ d: Database, property: UUID) throws -> [String: ([String], [[String]])] {
        let L = Lookup(d)
        let unit = try Property.fetchOne(d, id: property)?.unitSystem ?? .imperial
        let pw = "property_id = ?"
        let pa: StatementArguments = [property.db]
        func id(_ u: UUID?) -> String { u?.db ?? "" }
        func b(_ v: Bool?) -> String { v.map { $0 ? "true" : "false" } ?? "" }
        func num(_ v: Double?) -> String {
            guard let v else { return "" }
            return v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
        }
        func room(_ s: Scope) -> String { L.spaceName(s.spaceId) ?? "" }
        func floor(_ s: Scope) -> String { L.levelName(s.levelId) ?? "" }
        func disp(_ v: Double?) -> String { v.map { HomeLengthFormatter.format($0, system: unit) } ?? "" }
        var out: [String: ([String], [[String]])] = [:]

        let spaces = try Space.fetchAll(d, where: pw, pa).sorted { ($0.levelId.db, $0.sortOrder, $0.name) < ($1.levelId.db, $1.sortOrder, $1.name) }
        out["spaces.csv"] = (["id", "floor", "name", "type", "is_exterior", "area_sq_ft", "width_display", "depth_display", "source", "is_approximate"],
            spaces.map { s in
                let bb = s.bounds
                return [s.id.db, L.levelName(s.levelId) ?? "", s.name, s.spaceType.rawValue, b(s.isExterior),
                        String(format: "%.2f", Area.squareFeet(fromSquareInches: s.areaSqIn)), disp(bb.width), disp(bb.height),
                        s.source.rawValue, b(s.isApproximate)]
            })

        let chores = ChoreStore.sort(try Chore.fetchAll(d, where: pw, pa))
        out["chores.csv"] = (["id", "title", "room", "floor", "scope", "assignee", "repeat", "next_due_on", "due_time", "reminder_on",
                              "calendar_on", "linked_thing", "paused", "closed_at", "notes"],
            chores.map { c in
                [c.id.db, c.title, room(c.scope), floor(c.scope), c.scope.kind.rawValue, L.personName(c.assigneeId) ?? "",
                 c.repeatRule?.humanText ?? "", c.nextDueOn?.description ?? "",
                 c.dueMinutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "", b(c.remindEnabled), b(c.calendarEnabled),
                 L.thingName(c.linkedThingId) ?? "", b(c.isPaused), CSV.instant(c.closedAt), c.notes ?? ""]
            })

        let titles = Dictionary(chores.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let comps = try ChoreCompletion.fetchAll(d, where: pw, pa).sorted { $0.doneAt < $1.doneAt }
        out["chore_completions.csv"] = (["id", "chore_id", "chore_title", "due_on", "done_at", "done_by", "outcome", "note"],
            comps.map { x in
                [x.id.db, x.choreId.db, titles[x.choreId] ?? "", x.dueOn?.description ?? "", CSV.instant(x.doneAt),
                 L.personName(x.doneBy) ?? "", x.outcome.rawValue, x.note ?? ""]
            })

        let projects = try Project.fetchAll(d, where: pw, pa).sorted { $0.title < $1.title }
        let lines = try CostLineItem.fetchAll(d, where: pw, pa).sorted { ($0.createdAt, $0.id.db) < ($1.createdAt, $1.id.db) }
        out["projects.csv"] = (["id", "title", "room", "floor", "scope", "status", "est_cost", "actual_cost", "spent_effective", "currency",
                                "est_hours", "actual_hours", "target_on", "started_on", "completed_on", "vendor", "spawned_from_chore", "notes"],
            projects.map { p in
                [p.id.db, p.title, room(p.scope), floor(p.scope), p.scope.kind.rawValue, p.status.rawValue, p.estCost?.plainString ?? "",
                 p.actualCost?.plainString ?? "", Money(cents: RollupMath.spentCents(p, lineItems: lines), currency: p.currencyCode).plainString,
                 p.currencyCode, num(p.estHours), num(p.actualHours), p.targetOn?.description ?? "", p.startedOn?.description ?? "",
                 p.completedOn?.description ?? "", p.vendor ?? "", id(p.spawnedFromChoreId), p.notes ?? ""]
            })

        let ptitles = Dictionary(projects.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let attById = Dictionary(try Attachment.fetchAll(d, where: pw, pa).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        out["cost_line_items.csv"] = (["id", "project_id", "project_title", "label", "kind", "amount", "currency", "vendor", "incurred_on",
                                       "hours", "receipt_file"],
            lines.map { li in
                let receipt = li.receiptAttachmentId.flatMap { attById[$0] }.map { "\($0.ownerType.rawValue)-\($0.ownerId.db)-\($0.id.db).\($0.fileExt)" }
                return [li.id.db, li.projectId.db, ptitles[li.projectId] ?? "", li.label, li.kind.rawValue, li.amount.plainString,
                        li.amount.currency, li.vendor ?? "", li.incurredOn?.description ?? "", num(li.hours), receipt ?? ""]
            })

        let things = try Thing.fetchAll(d, where: pw, pa).sorted { $0.name < $1.name }
        out["things.csv"] = (["id", "category", "name", "ownership", "room", "floor", "template", "brand", "model", "serial", "purchase_date",
                              "purchase_price", "warranty_end", "width_in", "depth_in", "height_in", "attributes_json", "notes"],
            try things.map { t in
                [t.id.db, t.category.rawValue, t.name, t.ownership.rawValue, room(t.scope), floor(t.scope), t.templateKey ?? "",
                 t.brand ?? "", t.model ?? "", t.serial ?? "", t.purchaseDate?.description ?? "", t.purchasePrice?.plainString ?? "",
                 t.warrantyEnd?.description ?? "", CSV.inches(t.dims.width), CSV.inches(t.dims.depth), CSV.inches(t.dims.height),
                 try HomeJSON.encodeString(t.attributes), t.notes ?? ""]
            })

        let items = try InventoryItem.fetchAll(d, where: pw, pa).sorted { $0.name < $1.name }
        out["inventory.csv"] = (["id", "kind", "name", "category", "owner", "floor", "room", "spot_path", "quantity", "unit", "season",
                                 "in_rotation", "expires_on", "is_low", "linked_thing", "notes"],
            items.map { i in
                [i.id.db, i.kind.rawValue, i.name, i.category ?? "", L.personName(i.ownerId) ?? "", floor(i.scope), room(i.scope),
                 L.spotPath(i.storageSpotId) ?? "", num(i.quantity), i.unit ?? "", i.season?.rawValue ?? "", b(i.inRotation),
                 i.expiresOn?.description ?? "", b(i.isLow), L.thingName(i.linkedThingId) ?? "", i.notes ?? ""]
            })

        let ms = try HomeMeasurement.fetchAll(d, where: pw, pa).sorted { $0.label < $1.label }
        out["measurements.csv"] = (["id", "label", "kind", "floor", "room", "attached_to", "width_in", "depth_in", "height_in",
                                    "width_display", "depth_display", "height_display", "delivery_path", "note"],
            try ms.map { m in
                let level = try m.spaceId.flatMap { try Space.fetchOne(d, id: $0)?.levelId }
                var attached = ""
                if let oid = m.openingId, let o = try Opening.fetchOne(d, id: oid) { attached = o.kind.rawValue }
                else if let sid = m.storageSpotId { attached = "spot: " + (L.spotPath(sid) ?? "") }
                return [m.id.db, m.label, m.kind.rawValue, L.levelName(level) ?? "", L.spaceName(m.spaceId) ?? "", attached,
                        CSV.inches(m.dims.width), CSV.inches(m.dims.depth), CSV.inches(m.dims.height),
                        disp(m.dims.width), disp(m.dims.depth), disp(m.dims.height), b(m.isDeliveryPath), m.note ?? ""]
            })

        let spots = try StorageSpot.fetchAll(d, where: pw, pa)
        out["storage_spots.csv"] = (["id", "floor", "room", "path", "owner"],
            try spots.map { s -> [String] in
                let level = try Space.fetchOne(d, id: s.spaceId)?.levelId
                return [s.id.db, L.levelName(level) ?? "", L.spaceName(s.spaceId) ?? "", L.spotPath(s.id) ?? s.name, L.personName(s.ownerId) ?? ""]
            }.sorted { ($0[1], $0[2], $0[3]) < ($1[1], $1[2], $1[3]) })

        out["people.csv"] = (["id", "name"], try PeopleStore.list(d, property: property).map { [$0.id.db, $0.name] })

        // Budget summary: rooms per floor, floors, whole house, total.
        var budget: [[String]] = []
        func row(_ bucket: String, _ floorName: String, _ roomName: String, _ r: Rollup) -> [String] {
            [bucket, floorName, roomName, r.planned.plainString, r.ideas.plainString, r.spent.plainString, r.remaining.plainString,
             r.variance.plainString, num(r.plannedHours), num(r.spentHours)]
        }
        let pr = try RollupQueries.property(d, property)
        for lv in pr.levels {
            let rooms = try RollupQueries.rooms(d, level: lv.levelId)
            for s in spaces where s.levelId == lv.levelId {
                guard let r = rooms[s.id], !r.isEmpty else { continue }
                budget.append(row("Room", lv.levelName, s.name, r))
            }
            budget.append(row("Floor", lv.levelName, "", lv.rollup))
        }
        budget.append(row("Whole house", "", "", pr.wholeHouse))
        budget.append(row("Total", "", "", pr.total))
        out["budget_summary.csv"] = (["bucket", "floor", "room", "planned", "ideas", "spent", "remaining", "variance", "planned_hours", "spent_hours"], budget)
        return out
    }
}

// MARK: - Diagnostics (FR-SES-41..43)

/// Counts-only diagnostics (no titles, names, notes, addresses or photos) and its export.
public struct DiagnosticsStore: DiagnosticsService {
    public let db: AppDatabase
    /// `Application Support/Diagnostics` (MetricKit payloads written by the app), copied into the export when present.
    public let metricsDirectory: URL?
    public let outputDirectory: URL
    /// Extra files for the export, e.g. the app's 24-hour `OSLogStore` slice (written by the app, which owns
    /// `OSLog`); called at export time. Must not contain user content.
    public let additionalFiles: @Sendable () async -> [URL]
    public init(_ db: AppDatabase, metricsDirectory: URL? = nil, outputDirectory: URL = FileManager.default.temporaryDirectory,
                additionalFiles: @escaping @Sendable () async -> [URL] = { [] }) {
        self.db = db; self.metricsDirectory = metricsDirectory; self.outputDirectory = outputDirectory; self.additionalFiles = additionalFiles
    }

    public func counts(property: UUID) async throws -> DiagnosticsCounts {
        let today = db.clock.today
        let cal = db.clock.calendar
        return try await db.read { d in try Self.counts(d, property: property, today: today, calendar: cal) }
    }

    static func counts(_ d: Database, property: UUID, today: LocalDate, calendar: Calendar) throws -> DiagnosticsCounts {
        let p = [property.db]
        func n(_ sql: String) throws -> Int { try Int.fetchOne(d, sql: sql, arguments: StatementArguments(p)) ?? 0 }
        var c = DiagnosticsCounts()
        c.levels = try n("SELECT COUNT(*) FROM level WHERE property_id = ? AND deleted_at IS NULL")
        for r in try Row.fetchAll(d, sql: "SELECT source, COUNT(*) AS n FROM space WHERE property_id = ? AND deleted_at IS NULL GROUP BY source", arguments: StatementArguments(p)) {
            c.spacesBySource[r["source"] ?? "unknown"] = r["n"] ?? 0
        }
        for (k, t) in [("chore", "chore"), ("project", "project"), ("thing", "thing"), ("inventory_item", "inventory_item"), ("measurement", "measurement")] {
            c.itemsByKind[k] = try n("SELECT COUNT(*) FROM \(t) WHERE property_id = ? AND deleted_at IS NULL")
        }
        c.choresWithReminder = try n("SELECT COUNT(*) FROM chore WHERE property_id = ? AND deleted_at IS NULL AND remind_enabled = 1")
        c.choresWithCalendar = try n("SELECT COUNT(*) FROM chore WHERE property_id = ? AND deleted_at IS NULL AND calendar_enabled = 1")
        c.doneProjectsWithActual = try n("SELECT COUNT(*) FROM project WHERE property_id = ? AND deleted_at IS NULL AND status = 'done' AND actual_cost_cents IS NOT NULL")
        c.doneProjectsWithReceipt = try n("""
            SELECT COUNT(*) FROM project pr WHERE pr.property_id = ? AND pr.deleted_at IS NULL AND pr.status = 'done' AND (
              EXISTS (SELECT 1 FROM attachment a WHERE a.deleted_at IS NULL AND a.kind = 'receipt' AND a.owner_type = 'project' AND a.owner_id = pr.id) OR
              EXISTS (SELECT 1 FROM cost_line_item li WHERE li.deleted_at IS NULL AND li.project_id = pr.id AND li.receipt_attachment_id IS NOT NULL))
            """)
        // Completions per ISO week, last 8 weeks.
        let since = today.adding(days: -56).description
        var iso = Calendar(identifier: .iso8601); iso.timeZone = calendar.timeZone
        for s in try String.fetchAll(d, sql: "SELECT done_on FROM chore_completion WHERE property_id = ? AND deleted_at IS NULL AND done_on > ?",
                                     arguments: [property.db, since]) {
            guard let ld = LocalDate(string: s), let date = ld.date(atMinutes: 12 * 60, calendar: iso) else { continue }
            let comps = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            let key = String(format: "%04d-W%02d", comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
            c.completionsPerWeek[key, default: 0] += 1
        }
        if let first: Date = try Date.fetchOne(d, sql: "SELECT MIN(created_at) FROM space WHERE property_id = ?", arguments: [property.db]) {
            c.firstPlanCreatedOn = LocalDate(first, calendar: calendar)
        }
        return c
    }

    public func exportDiagnostics(property: UUID) async throws -> URL {
        let counts = try await counts(property: property)
        let work = outputDirectory.appendingPathComponent("home-diagnostics-\(UUID().uuidString.lowercased())", isDirectory: true)
        let name = "Home-Diagnostics-\(db.clock.today)"
        let folder = work.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try HomeJSON.encoder().encode(counts).write(to: folder.appendingPathComponent("counts.json"))
        let meta: [String: String] = ["schema": "v1_core,v1_local,v1_search", "dbBytes": String(db.fileSizeBytes)]
        try HomeJSON.encoder().encode(meta).write(to: folder.appendingPathComponent("database.json"))
        if let m = metricsDirectory, FileManager.default.fileExists(atPath: m.path) {
            try? FileManager.default.copyItem(at: m, to: folder.appendingPathComponent("MetricKit", isDirectory: true))
        }
        for f in await additionalFiles() {
            try? FileManager.default.copyItem(at: f, to: folder.appendingPathComponent(f.lastPathComponent))
        }
        return try CSVExporter.zip(folder: folder, name: name, into: work)
    }
}
