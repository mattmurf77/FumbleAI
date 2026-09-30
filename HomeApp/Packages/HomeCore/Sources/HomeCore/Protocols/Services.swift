import Foundation
import PlanKit

// Query services, platform adapters, capture and exterior protocols (LLD §14). All value-typed; no GRDB,
// CloudKit, EventKit, UserNotifications, RoomPlan, MapKit or CoreLocation types cross these boundaries.

// MARK: - Queries

/// Full-text search (FTS5 in HomeStore). LLD §12.
public protocol SearchService: Sendable {
    /// AND prefix match, falling back to OR when empty; ≤ 50 hits ordered by rank.
    func search(_ text: String, property: UUID) async throws -> [SearchHit]
    /// Diagnostics: "Rebuild search index".
    func rebuildIndex() async throws
}

/// Budget rollups (LLD §8, `BudgetServicing`).
public protocol RollupService: Sendable {
    func observeRooms(level: UUID) -> AsyncStream<[UUID: Rollup]>
    func observeFloor(level: UUID) -> AsyncStream<FloorRollup>
    func observeProperty(_ id: UUID) -> AsyncStream<PropertyRollup>
}
public typealias BudgetServicing = RollupService

/// Per-level lens statistics for the canvas (LLD §7.4–7.5). PlanCanvas consumes `LensStats` values only.
public protocol LensStatsService: Sendable {
    func observeStats(level: UUID, today: LocalDate) -> AsyncStream<LensStats>
}

/// CSV export (LLD §13): returns the URL of `Home-Export-YYYY-MM-DD.zip` (or a folder on platforms without zip).
public protocol ExportService: Sendable {
    func exportCSV(property: UUID, options: ExportOptions) async throws -> URL
}
public typealias ExportServicing = ExportService

/// Diagnostics (FR-SES-41..43).
public protocol DiagnosticsService: Sendable {
    func counts(property: UUID) async throws -> DiagnosticsCounts
    /// Zip with a 24-hour log slice, MetricKit payloads and the counts-only JSON.
    func exportDiagnostics(property: UUID) async throws -> URL
}

// MARK: - Reminders / calendar (HomeSchedule)

/// Reschedules local notifications from the planner (debounced 500 ms, coalesces reasons). LLD §9.3.
public protocol ReminderScheduling: Sendable {
    func replan(reason: ReplanReason) async
    func status() async -> ReminderStatus
    /// Records a SNOOZE_1H action and replans.
    func snooze(chore: UUID, for seconds: TimeInterval) async
}

/// Notification permission (requested only when the first reminder is switched on).
public protocol NotificationAuthorizing: Sendable {
    func authorizationStatus() async -> PermissionStatus
    /// Requests .alert, .sound, .badge. Returns granted.
    func requestAuthorization() async throws -> Bool
}

/// EventKit calendar sync, owner-device model, one-way (app is master). LLD §9.5.
public protocol CalendarSyncing: Sendable {
    func authorizationStatus() async -> PermissionStatus
    /// `requestFullAccessToEvents`. Returns granted.
    func requestAccess() async throws -> Bool
    func writableCalendars() async -> [CalendarInfo]
    /// "Create 'Home' calendar" (iCloud source, else local).
    func createHomeCalendar() async throws -> CalendarInfo
    func ownership(chore: UUID) async -> CalendarOwnership
    func enable(chore: UUID, calendarId: String) async throws
    func choreChanged(_ id: UUID) async
    func choreCompleted(_ id: UUID) async
    func disable(chore: UUID) async
    /// "Manage from this iPhone".
    func adoptOwnership(chore: UUID) async throws
    /// Detects events deleted in the Calendar app (EKEventStoreChanged, BG refresh).
    func reconcileOwned() async
}

// MARK: - Sync (HomeSync)

public protocol SyncServicing: Sendable {
    func start() async throws
    func observeStatus() -> AsyncStream<SyncStatus>
    func syncNow() async throws
    /// First launch on a new device: fetch with an 8 s timeout and look for `property-*` zones (HLD §5.2).
    func restoreCheck(timeout: TimeInterval) async -> RestoreCheckResult
    func diagnostics() async -> SyncDiagnostics
}

// MARK: - Capture (HomeCapture)

/// Marker for the four plan-creation paths (each produces a `PlanDraft`).
public protocol PlanDraftProducing: Sendable {}

/// RoomPlan `CapturedStructure` → `PlanDraft` (§6.12). Input is the structure's JSON (it is `Codable`), so this
/// contract stays free of RoomPlan types. `storyMap`: RoomPlan story index → level kind chosen on review.
public protocol RoomPlanImporting: PlanDraftProducing {
    func draft(fromCapturedStructureJSON data: Data, storyMap: [Int: Level.Kind]) throws -> PlanDraft
}

/// "Rough it in" (§6.10): deterministic for the same input.
public protocol RoughInGenerating: PlanDraftProducing {
    func draft(_ input: RoughInInput) -> PlanDraft
}

/// "Build with blocks" starting templates.
public protocol BlockTemplating: PlanDraftProducing {
    func draft(style: HouseStyle, beds: Int, baths: Double) -> PlanDraft
}

/// Photo-trace scale calibration (§6.9). Points are image **pixel** coordinates.
public protocol PhotoTraceCalibrating: PlanDraftProducing {
    func calibrate(a: Vec2, b: Vec2, lengthIn: Double, second: (Vec2, Vec2, Double)?, imageSize: Vec2,
                   contentCenter: Vec2) -> Result<UnderlayTransform, TraceWarning>
}

/// Receipt OCR (§15): images as encoded data (HEIC/JPEG/PNG) → suggested total/date/vendor.
public protocol ReceiptReading: Sendable {
    func read(images: [Data]) async throws -> ReceiptGuess
}

/// Pure receipt parser over OCR lines (table-tested).
public protocol ReceiptParsing: Sendable {
    func parse(lines: [OCRLine], today: LocalDate) -> ReceiptGuess
}

// MARK: - Exterior (HomeExterior)

/// Address search (MKLocalSearchCompleter / MKLocalSearch).
public protocol AddressResolving: Sendable {
    func suggestions(for query: String) async throws -> [AddressSuggestion]
    func resolve(_ query: String) async throws -> ResolvedAddress
}

/// Building footprint + nearest road near a coordinate.
///
/// **Source selection:** when `AppConfig.serverURL` (Info.plist `HomeServerURL`) is set, call the Home server
/// `GET {HomeServerURL}/v1/footprint?lat=&lon=` with header `X-Home-Key: {HomeAPIKey}` when the key is non-empty;
/// otherwise POST the Overpass query (§6.11) directly to `https://overpass-api.de/api/interpreter` (15 s timeout,
/// `User-Agent: Home/1.0`). Returns nil when nothing is found (the caller falls back to a 40 × 30 ft rectangle).
public protocol FootprintProviding: Sendable {
    func footprint(near: GeoCoordinate) async throws -> FootprintResult?
}

/// MKMapSnapshotter satellite image, cached locally (never synced).
public protocol SatelliteSnapshotting: Sendable {
    func snapshot(center: GeoCoordinate, spanMeters: Double, levelId: UUID) async throws -> SnapshotImage
}

/// Default yard zones around a footprint (§6.11). `footprint` in level inches; nil → 40 × 30 ft fallback.
public protocol YardSeeding: Sendable {
    func seed(footprint: Polygon?, frontDir: Vec2, roadDistanceIn: Double?) -> [SpaceDraft]
}

/// Orchestrates address → footprint → projection → yard zones into an exterior `LevelDraft` (HLD §4.5).
public protocol ExteriorSeeding: Sendable {
    func exteriorLevel(for address: ResolvedAddress) async -> LevelDraft
}
