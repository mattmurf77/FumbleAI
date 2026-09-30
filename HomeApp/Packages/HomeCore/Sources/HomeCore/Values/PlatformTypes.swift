import Foundation
import PlanKit

// MARK: - Notifications / reminders

public enum ReplanReason: String, Hashable, Sendable, Codable {
    case launch, foreground, choreChanged, syncApplied, timeZoneChanged, notificationAction, backgroundRefresh, settingsChanged, manual
}

public enum PermissionStatus: String, Hashable, Sendable, Codable {
    case notDetermined, denied, authorized, provisional, restricted, writeOnly, unknown
    public var isGranted: Bool { self == .authorized || self == .provisional }
}

/// Diagnostics snapshot of the scheduled reminder set (Settings › Diagnostics: "x/64").
public struct ReminderStatus: Hashable, Sendable, Codable {
    public var pendingCount: Int
    public var limit: Int
    public var authorization: PermissionStatus
    public var lastReplanAt: Date?
    public init(pendingCount: Int = 0, limit: Int = 64, authorization: PermissionStatus = .notDetermined, lastReplanAt: Date? = nil) {
        self.pendingCount = pendingCount; self.limit = limit; self.authorization = authorization; self.lastReplanAt = lastReplanAt
    }
}

// MARK: - Calendar

/// A writable calendar (EventKit-free description). Grouped in the picker by `sourceTitle`.
public struct CalendarInfo: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    /// "iCloud", "Gmail – you@…", "Exchange".
    public var sourceTitle: String
    public var colorHex: String?
    public init(id: String, title: String, sourceTitle: String, colorHex: String? = nil) {
        self.id = id; self.title = title; self.sourceTitle = sourceTitle; self.colorHex = colorHex
    }
}

/// How a chore's calendar events are managed from this device.
public enum CalendarOwnership: Hashable, Sendable {
    case notEnabled
    case ownedByThisDevice(calendar: String)
    /// "Calendar events are managed on '<nickname>'".
    case ownedByOtherDevice(nickname: String)
}

// MARK: - Sync

public enum SyncStatus: Hashable, Sendable, Codable {
    case upToDate(lastSync: Date?)
    case syncing
    case waitingForNetwork
    case pending(count: Int)
    case iCloudOff
    case quotaExceeded
    case error(String)

    /// Settings pill text (spec 09).
    public var displayText: String {
        switch self {
        case .upToDate: return "Up to date"; case .syncing: return "Syncing…"; case .waitingForNetwork: return "Waiting for network"
        case .pending(let n): return "\(n) change\(n == 1 ? "" : "s") pending"; case .iCloudOff: return "iCloud off – not syncing"
        case .quotaExceeded: return "iCloud storage full"; case .error(let e): return "Sync error: \(e)"
        }
    }
}

public struct SyncDiagnostics: Hashable, Sendable, Codable {
    public var accountStatus: String
    public var lastFetchAt: Date?
    public var lastSendAt: Date?
    public var outboxCount: Int
    public var parkedOrphans: Int
    public var lastError: String?
    public init(accountStatus: String = "unknown", lastFetchAt: Date? = nil, lastSendAt: Date? = nil, outboxCount: Int = 0,
                parkedOrphans: Int = 0, lastError: String? = nil) {
        self.accountStatus = accountStatus; self.lastFetchAt = lastFetchAt; self.lastSendAt = lastSendAt
        self.outboxCount = outboxCount; self.parkedOrphans = parkedOrphans; self.lastError = lastError
    }
}

/// Result of the first-launch restore check (HLD §5.2).
public enum RestoreCheckResult: Hashable, Sendable {
    /// A `property-*` zone exists: show "Restoring your home…".
    case existingHomeFound(propertyId: UUID)
    case noExistingHome
    /// iCloud unavailable or timed out (8 s): proceed to onboarding.
    case unavailable
}

// MARK: - Exterior

public struct AddressSuggestion: Hashable, Sendable, Codable, Identifiable {
    public var title: String
    public var subtitle: String
    public var id: String { title + "|" + subtitle }
    public init(title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
}

public struct ResolvedAddress: Hashable, Sendable, Codable {
    public var address: PostalAddressLite
    public var coordinate: GeoCoordinate
    public var displayName: String
    public init(address: PostalAddressLite, coordinate: GeoCoordinate, displayName: String) {
        self.address = address; self.coordinate = coordinate; self.displayName = displayName
    }
}

/// Building footprint + nearest road, in geographic coordinates (projection happens in HomeExterior). §6.11.
public struct FootprintResult: Hashable, Sendable, Codable {
    /// Building outline ring (lat/lon), not closed.
    public var outline: [GeoCoordinate]
    /// Nearest point on a nearby road way to the footprint centroid, if any.
    public var nearestRoadPoint: GeoCoordinate?
    /// "overpass" or "server".
    public var source: String
    public init(outline: [GeoCoordinate], nearestRoadPoint: GeoCoordinate?, source: String) {
        self.outline = outline; self.nearestRoadPoint = nearestRoadPoint; self.source = source
    }
}

/// Cached satellite snapshot (local only, never synced; ADR-12).
public struct SnapshotImage: Hashable, Sendable, Codable {
    /// Caches/Snapshots/<levelId>.heic
    public var fileURL: URL
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixel → level-model (inches) mapping, fitted from the 4 corners.
    public var pixelToModel: Transform2D
    public var createdAt: Date
    public init(fileURL: URL, pixelWidth: Int, pixelHeight: Int, pixelToModel: Transform2D, createdAt: Date) {
        self.fileURL = fileURL; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.pixelToModel = pixelToModel; self.createdAt = createdAt
    }
    public static let maxAgeDays = 180
}

// MARK: - Capture

/// "Rough it in" inputs (§6.10).
public struct RoughInInput: Hashable, Sendable, Codable {
    /// 1–3 above grade.
    public var floors: Int
    public var hasBasement: Bool
    /// Total above-grade square feet.
    public var approxSqFt: Int
    public var bedrooms: Int
    /// Half baths as .5.
    public var bathrooms: Double
    public var includeGarage: Bool
    /// Optional house style. `.biLevel` makes a Main Level over a Lower Level (split foyer) and ignores
    /// `floors` / `hasBasement`; nil (and every other style) uses the floors / basement inputs.
    public var style: HouseStyle?
    public init(floors: Int, hasBasement: Bool, approxSqFt: Int, bedrooms: Int, bathrooms: Double, includeGarage: Bool = false,
                style: HouseStyle? = nil) {
        self.floors = floors; self.hasBasement = hasBasement; self.approxSqFt = approxSqFt
        self.bedrooms = bedrooms; self.bathrooms = bathrooms; self.includeGarage = includeGarage; self.style = style
    }
}

/// "Build with blocks" / "Rough it in" house styles. Product names: Ranch, Colonial 2-story (`twoStory`),
/// Split-level, Bi-level (split foyer), Cape (`capeCod`), Townhouse, Condo (`apartment`).
/// Forward compatible: a style written by a newer app decodes to `.unknown`; use `knownCases` for pickers.
public enum HouseStyle: String, ForwardCompatibleEnum {
    case ranch, twoStory, splitLevel, capeCod, townhouse, apartment
    /// Split foyer: the front door opens onto a mid-level landing with a short flight up to the main living level
    /// and a short flight down to a partly below-grade lower level.
    case biLevel
    case unknown
    public static var unknownCase: HouseStyle { .unknown }

    /// Picker order (Blank is not a style).
    public static let pickerOrder: [HouseStyle] = [.ranch, .twoStory, .capeCod, .splitLevel, .biLevel, .townhouse, .apartment]

    /// Product display name.
    public var displayName: String {
        switch self {
        case .ranch: return "Ranch"; case .twoStory: return "Colonial 2-story"; case .splitLevel: return "Split-level"
        case .biLevel: return "Bi-level"; case .capeCod: return "Cape"; case .townhouse: return "Townhouse"
        case .apartment: return "Condo"; case .unknown: return "Other"
        }
    }

    /// One-line description for the style picker.
    public var subtitle: String {
        switch self {
        case .ranch: return "One floor, attached garage"
        case .twoStory: return "Living downstairs, bedrooms up"
        case .splitLevel: return "Three short levels"
        case .biLevel: return "Split foyer: main floor up, family room and garage down"
        case .capeCod: return "Primary down, bedrooms under the roof"
        case .townhouse: return "Narrow and tall, shared walls"
        case .apartment: return "One floor, no yard"
        case .unknown: return "A style from a newer version of the app"
        }
    }

    /// SF Symbol for the style picker.
    public var symbol: String {
        switch self {
        case .ranch: return "house"; case .twoStory: return "building"; case .capeCod: return "house.lodge"
        case .splitLevel: return "stairs"; case .biLevel: return "arrow.up.and.down.square"; case .townhouse: return "building.2"
        case .apartment: return "building.columns"; case .unknown: return "questionmark.square.dashed"
        }
    }

    /// More than one interior level (stairs are part of the template).
    public var isMultiLevel: Bool {
        switch self {
        case .ranch, .apartment, .unknown: return false
        case .twoStory, .splitLevel, .biLevel, .capeCod, .townhouse: return true
        }
    }
}

public enum TraceWarning: Error, Hashable, Sendable {
    case possiblyStretched(ratio: Double)
    case invalidInput
}

/// Parsed receipt values — each is a suggestion the user must confirm (§15).
public struct ReceiptGuess: Hashable, Sendable, Codable {
    public var total: Money?
    public var date: LocalDate?
    public var vendor: String?
    public var fullText: String
    public init(total: Money? = nil, date: LocalDate? = nil, vendor: String? = nil, fullText: String = "") {
        self.total = total; self.date = date; self.vendor = vendor; self.fullText = fullText
    }
}

/// One recognized OCR line with its vertical position (0 = top, 1 = bottom), for `ReceiptParsing`.
public struct OCRLine: Hashable, Sendable, Codable {
    public var text: String
    public var y: Double
    public init(text: String, y: Double) { self.text = text; self.y = y }
}

// MARK: - Export / diagnostics

public struct ExportOptions: Hashable, Sendable, Codable {
    public var includeAttachments: Bool
    public init(includeAttachments: Bool = false) { self.includeAttachments = includeAttachments }
}

/// Counts-only diagnostics JSON (FR-SES-42): no titles, names, notes, addresses or photos.
public struct DiagnosticsCounts: Hashable, Sendable, Codable {
    public var levels: Int = 0
    public var spacesBySource: [String: Int] = [:]
    public var itemsByKind: [String: Int] = [:]
    public var choresWithReminder: Int = 0
    public var choresWithCalendar: Int = 0
    /// ISO week ("2026-W39") → completions, last 8 weeks.
    public var completionsPerWeek: [String: Int] = [:]
    public var doneProjectsWithActual: Int = 0
    public var doneProjectsWithReceipt: Int = 0
    public var firstPlanCreatedOn: LocalDate?
    public init() {}
}
