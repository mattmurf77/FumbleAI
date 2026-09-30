import Foundation

/// Clothing season. Top-level so `Season.upcoming` can live next to it. LLD §11.4.
public enum Season: String, ForwardCompatibleEnum {
    case summer, winter, allYear = "all_year", unknown
    public static var unknownCase: Season { .unknown }

    /// Northern hemisphere: Mar–Aug → summer, Sep–Feb → winter; southern hemisphere (latitude < 0) shifts by 6 months.
    public static func upcoming(on date: LocalDate, latitude: Double? = nil) -> Season {
        let northern: Season = (3...8).contains(date.month) ? .summer : .winter
        guard let lat = latitude, lat < 0 else { return northern }
        return northern.opposite
    }

    public var opposite: Season {
        switch self { case .summer: return .winter; case .winter: return .summer; default: return self }
    }
}

/// Pantry, clothing, stored or other items. LLD §3.2 `inventory_item`, §11.
public struct InventoryItem: SyncedModel {
    public static let recordType = RecordType.inventoryItem
    public typealias Season = HomeCore.Season
    public enum Kind: String, ForwardCompatibleEnum {
        case pantry, clothing, stored, other, unknown
        public static var unknownCase: Kind { .unknown }
    }
    public var id: UUID
    public var propertyId: UUID
    public var kind: Kind
    public var name: String
    /// clothing: 'coat','boots',...; pantry: 'canned','spices',...
    public var category: String?
    public var ownerId: UUID?
    /// When `storageSpotId` is set, scope must be `.space` (the spot's room). Space/level are denormalized.
    public var scope: Scope
    public var storageSpotId: UUID?
    public var quantity: Double
    /// 'ea','lb','oz','can','box','pair'.
    public var unit: String?
    public var season: Season?
    /// Clothing: true in rotation, false stored.
    public var inRotation: Bool?
    public var expiresOn: LocalDate?
    public var isLow: Bool
    /// Auto-flag low when quantity <= threshold.
    public var lowThreshold: Double?
    /// Spare filters/bulbs for a fixture.
    public var linkedThingId: UUID?
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, kind: Kind, name: String, category: String? = nil,
                ownerId: UUID? = nil, scope: Scope, storageSpotId: UUID? = nil, quantity: Double = 1, unit: String? = nil,
                season: Season? = nil, inRotation: Bool? = nil, expiresOn: LocalDate? = nil, isLow: Bool = false,
                lowThreshold: Double? = nil, linkedThingId: UUID? = nil, notes: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.kind = kind; self.name = name; self.category = category
        self.ownerId = ownerId; self.scope = scope; self.storageSpotId = storageSpotId; self.quantity = quantity
        self.unit = unit; self.season = season; self.inRotation = inRotation; self.expiresOn = expiresOn
        self.isLow = isLow; self.lowThreshold = lowThreshold; self.linkedThingId = linkedThingId; self.notes = notes
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    /// Expiring within `days` of `today` (pantry).
    public func isExpiring(today: LocalDate, withinDays days: Int = 7) -> Bool {
        guard let e = expiresOn else { return false }
        return e <= today.adding(days: days)
    }
}

/// Photo, receipt, manual, document or plan underlay. Binary lives in `Attachments/<id>.<ext>`. LLD §3.2, §5.6.
public struct Attachment: SyncedModel {
    public static let recordType = RecordType.attachment
    public enum OwnerType: String, ForwardCompatibleEnum {
        case chore, choreCompletion = "chore_completion", project, costLineItem = "cost_line_item", thing
        case inventoryItem = "inventory_item", measurement, space, level, storageSpot = "storage_spot", unknown
        public static var unknownCase: OwnerType { .unknown }
    }
    public enum Kind: String, ForwardCompatibleEnum {
        case photo, receipt, manual, document, underlay, unknown
        public static var unknownCase: Kind { .unknown }
    }
    public var id: UUID
    public var propertyId: UUID
    public var ownerType: OwnerType
    public var ownerId: UUID
    public var kind: Kind
    /// 'heic','jpg','pdf','png'.
    public var fileExt: String
    public var uti: String
    public var byteSize: Int
    public var widthPx: Int?
    public var heightPx: Int?
    public var sha256: String
    public var caption: String?
    /// Vision OCR text (receipts, manuals), indexed for search.
    public var ocrText: String?
    public var capturedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), propertyId: UUID, ownerType: OwnerType, ownerId: UUID, kind: Kind,
                fileExt: String, uti: String, byteSize: Int, widthPx: Int? = nil, heightPx: Int? = nil,
                sha256: String, caption: String? = nil, ocrText: String? = nil, capturedAt: Date? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.propertyId = propertyId; self.ownerType = ownerType; self.ownerId = ownerId; self.kind = kind
        self.fileExt = fileExt; self.uti = uti; self.byteSize = byteSize; self.widthPx = widthPx; self.heightPx = heightPx
        self.sha256 = sha256; self.caption = caption; self.ocrText = ocrText; self.capturedAt = capturedAt
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    /// Relative file name in Application Support/Attachments.
    public var fileName: String { "\(id.uuidString.lowercased()).\(fileExt)" }
    /// Max PDF size (§5.6): 25 MB.
    public static let maxPDFBytes = 25 * 1024 * 1024
    /// Photos are downsampled to this long edge (§5.6).
    public static let maxPhotoLongEdgePx = 3000
}

/// Device-local preferences (UserDefaults; not synced). Synced settings — default floor, units, currency —
/// live on `Property`. Spec 09 FR-SES-40.
public struct AppSettings: Hashable, Codable, Sendable {
    /// Default time for all-day chores' reminders (minutes after midnight), 9:00.
    public var defaultAllDayMinutes: MinuteOfDay
    public var defaultRemindOffsetMin: Int
    public var badgeEnabled: Bool
    /// Pantry expiry digest (HLD §9-9), off by default.
    public var pantryDigestEnabled: Bool
    /// EKCalendar identifier last chosen ("remembered as default").
    public var defaultCalendarId: String?
    /// "Also alert from Calendar" (adds an EKAlarm).
    public var alsoAlertFromCalendar: Bool
    /// This device's nickname for "Calendar events are managed on '<nickname>'".
    public var deviceNickname: String
    /// "Show plan as list" (auto-on with VoiceOver).
    public var showPlanAsList: Bool
    /// Last selected lens (restored on launch).
    public var lastLens: LensID
    /// Last selected level per property.
    public var lastLevelId: UUID?
    /// Spare-stock prompt after completing a linked chore (HLD §9-20).
    public var spareStockPromptEnabled: Bool

    public init(defaultAllDayMinutes: MinuteOfDay = Chore.defaultAllDayMinutes, defaultRemindOffsetMin: Int = 0,
                badgeEnabled: Bool = true, pantryDigestEnabled: Bool = false, defaultCalendarId: String? = nil,
                alsoAlertFromCalendar: Bool = false, deviceNickname: String = "iPhone", showPlanAsList: Bool = false,
                lastLens: LensID = .plan, lastLevelId: UUID? = nil, spareStockPromptEnabled: Bool = true) {
        self.defaultAllDayMinutes = defaultAllDayMinutes; self.defaultRemindOffsetMin = defaultRemindOffsetMin
        self.badgeEnabled = badgeEnabled; self.pantryDigestEnabled = pantryDigestEnabled
        self.defaultCalendarId = defaultCalendarId; self.alsoAlertFromCalendar = alsoAlertFromCalendar
        self.deviceNickname = deviceNickname; self.showPlanAsList = showPlanAsList; self.lastLens = lastLens
        self.lastLevelId = lastLevelId; self.spareStockPromptEnabled = spareStockPromptEnabled
    }
}
