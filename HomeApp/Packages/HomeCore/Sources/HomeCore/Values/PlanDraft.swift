import Foundation
import PlanKit

/// The shared output of all four plan-creation paths (Scan, Blocks, Trace, Rough) and exterior seeding.
/// `PlanCommitting.commit` writes a draft in one transaction. LLD §6.13.
public struct PlanDraft: Hashable, Codable, Sendable {
    public var levels: [LevelDraft]
    public var source: Space.Source
    public init(levels: [LevelDraft], source: Space.Source) { self.levels = levels; self.source = source }

    public var allWarnings: [DraftWarning] { levels.flatMap(\.warnings) }
    public var allSuggestions: [SuggestedThing] { levels.flatMap(\.suggestedThings) }
}

public struct LevelDraft: Hashable, Codable, Sendable, Identifiable {
    public var tempId: UUID
    public var name: String
    public var kind: Level.Kind
    public var sortOrder: Int
    public var spaces: [SpaceDraft]
    public var openings: [OpeningDraft]
    /// Suggested Things (RoomPlan objects) — the user must accept each one (§6.12 step 9).
    public var suggestedThings: [SuggestedThing]
    public var measurements: [MeasurementDraft]
    public var underlay: UnderlayDraft?
    public var georef: GeoReference?
    /// Rigid 2D alignment applied at commit (multi-floor scans, §6.12 step 10). nil = identity.
    public var alignment: Transform2D?
    /// RoomPlan story index this level came from (review screen maps stories → floors).
    public var storyIndex: Int?
    public var warnings: [DraftWarning]
    public var id: UUID { tempId }

    public init(tempId: UUID = UUID(), name: String, kind: Level.Kind = .floor, sortOrder: Int = 0,
                spaces: [SpaceDraft] = [], openings: [OpeningDraft] = [], suggestedThings: [SuggestedThing] = [],
                measurements: [MeasurementDraft] = [], underlay: UnderlayDraft? = nil, georef: GeoReference? = nil,
                alignment: Transform2D? = nil, storyIndex: Int? = nil, warnings: [DraftWarning] = []) {
        self.tempId = tempId; self.name = name; self.kind = kind; self.sortOrder = sortOrder; self.spaces = spaces
        self.openings = openings; self.suggestedThings = suggestedThings; self.measurements = measurements
        self.underlay = underlay; self.georef = georef; self.alignment = alignment; self.storyIndex = storyIndex
        self.warnings = warnings
    }

    public var bounds: Rect { spaces.reduce(Rect.null) { $0.union($1.polygon.bounds) } }
}

public struct SpaceDraft: Hashable, Codable, Sendable, Identifiable {
    public var tempId: UUID
    public var name: String
    public var spaceType: SpaceType
    public var isExterior: Bool
    public var polygon: Polygon
    public var source: Space.Source
    public var isApproximate: Bool
    public var colorHex: String?
    public var id: UUID { tempId }

    public init(tempId: UUID = UUID(), name: String, spaceType: SpaceType = .room, isExterior: Bool = false,
                polygon: Polygon, source: Space.Source, isApproximate: Bool = false, colorHex: String? = nil) {
        self.tempId = tempId; self.name = name; self.spaceType = spaceType; self.isExterior = isExterior
        self.polygon = polygon; self.source = source; self.isApproximate = isApproximate; self.colorHex = colorHex
    }
}

public struct OpeningDraft: Hashable, Codable, Sendable, Identifiable {
    public var tempId: UUID
    public var spaceTempId: UUID?
    public var kind: Opening.Kind
    public var segment: Segment
    public var heightIn: Double?
    public var sillIn: Double?
    public var swing: Opening.Swing?
    public var isExteriorDoor: Bool
    public var id: UUID { tempId }
    public init(tempId: UUID = UUID(), spaceTempId: UUID? = nil, kind: Opening.Kind, segment: Segment,
                heightIn: Double? = nil, sillIn: Double? = nil, swing: Opening.Swing? = nil, isExteriorDoor: Bool = false) {
        self.tempId = tempId; self.spaceTempId = spaceTempId; self.kind = kind; self.segment = segment
        self.heightIn = heightIn; self.sillIn = sillIn; self.swing = swing; self.isExteriorDoor = isExteriorDoor
    }
}

/// A Thing suggested by capture (e.g. RoomPlan found a refrigerator). Named `ThingDraft` in LLD §6.13; renamed
/// to avoid clashing with the form input `ThingDraft`.
public struct SuggestedThing: Hashable, Codable, Sendable, Identifiable {
    public var tempId: UUID
    public var spaceTempId: UUID?
    public var category: Thing.Category
    public var templateKey: String?
    public var name: String
    public var dims: Dims3
    public var pin: Vec2?
    public var id: UUID { tempId }
    public init(tempId: UUID = UUID(), spaceTempId: UUID?, category: Thing.Category, templateKey: String?, name: String,
                dims: Dims3 = .empty, pin: Vec2? = nil) {
        self.tempId = tempId; self.spaceTempId = spaceTempId; self.category = category; self.templateKey = templateKey
        self.name = name; self.dims = dims; self.pin = pin
    }
}

public struct MeasurementDraft: Hashable, Codable, Sendable, Identifiable {
    public var tempId: UUID
    public var label: String
    public var kind: HomeMeasurement.Kind
    public var spaceTempId: UUID?
    public var openingTempId: UUID?
    public var dims: Dims3
    public var pin: Vec2?
    public var segment: Segment?
    public var isDeliveryPath: Bool
    public var source: HomeMeasurement.Source
    public var id: UUID { tempId }
    public init(tempId: UUID = UUID(), label: String, kind: HomeMeasurement.Kind, spaceTempId: UUID? = nil,
                openingTempId: UUID? = nil, dims: Dims3, pin: Vec2? = nil, segment: Segment? = nil,
                isDeliveryPath: Bool = false, source: HomeMeasurement.Source) {
        self.tempId = tempId; self.label = label; self.kind = kind; self.spaceTempId = spaceTempId
        self.openingTempId = openingTempId; self.dims = dims; self.pin = pin; self.segment = segment
        self.isDeliveryPath = isDeliveryPath; self.source = source
    }
}

/// Photo-trace underlay to store as `attachment(kind='underlay')` at commit.
public struct UnderlayDraft: Hashable, Codable, Sendable {
    public var image: AttachmentDraft
    public var transform: UnderlayTransform
    public init(image: AttachmentDraft, transform: UnderlayTransform) { self.image = image; self.transform = transform }
}

public enum DraftWarning: Hashable, Codable, Sendable {
    /// Interior spaces overlap by more than 1 sq ft (review required).
    case overlap(spaceIds: [UUID])
    /// Weld failed; the pre-weld polygon was kept.
    case weldFailed(spaceId: UUID)
    /// Room polygon fell back to the convex hull of the walls.
    case hullFallback(spaceId: UUID)
    /// Photo trace: the two calibrations disagree by > 5 %.
    case possiblyStretched
    /// No building footprint found; a 40 × 30 ft placeholder was used.
    case footprintFallback
    case other(String)
}

/// A local file to be stored as an attachment (the repository copies it into Attachments/ and computes sha256).
public struct AttachmentDraft: Hashable, Codable, Sendable {
    public var fileURL: URL
    public var kind: Attachment.Kind
    public var fileExt: String
    public var uti: String
    public var widthPx: Int?
    public var heightPx: Int?
    public var caption: String?
    public var ocrText: String?
    public var capturedAt: Date?
    public init(fileURL: URL, kind: Attachment.Kind, fileExt: String? = nil, uti: String = "public.data",
                widthPx: Int? = nil, heightPx: Int? = nil, caption: String? = nil, ocrText: String? = nil, capturedAt: Date? = nil) {
        self.fileURL = fileURL; self.kind = kind; self.fileExt = fileExt ?? fileURL.pathExtension.lowercased()
        self.uti = uti; self.widthPx = widthPx; self.heightPx = heightPx; self.caption = caption
        self.ocrText = ocrText; self.capturedAt = capturedAt
    }
}
