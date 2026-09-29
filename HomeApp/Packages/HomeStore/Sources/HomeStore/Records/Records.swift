import Foundation
import GRDB
import HomeCore
import PlanKit

/// A HomeCore synced model stored in one SQLite table. Conformances flatten `Scope`, `Vec2`, `Segment`, `Dims3`,
/// `Money` and JSON fields into the LLD §3.2 columns.
protocol DatabaseModel: SyncedModel {
    static var selectSQL: String { get }
    init(row: Row) throws
    func columns() throws -> Columns
    /// Local derived caches (not synced, not in outbox changed-fields).
    static var derivedColumns: Set<String> { get }
}

extension DatabaseModel {
    static var table: String { recordType.tableName }
    static var selectSQL: String { "SELECT * FROM \(recordType.tableName)" }
    static var derivedColumns: Set<String> { [] }
    var ref: RecordRef { RecordRef(Self.recordType, id) }
    var zoneName: String { Property.zoneName(for: propertyId) }

    static func fetchOne(_ db: Database, id: UUID, includeDeleted: Bool = true) throws -> Self? {
        let sql = selectSQL + " WHERE id = ?" + (includeDeleted ? "" : " AND deleted_at IS NULL")
        return try Row.fetchOne(db, sql: sql, arguments: [id.db]).map(Self.init(row:))
    }

    /// Live rows matching `whereSQL` (without the WHERE keyword).
    static func fetchAll(_ db: Database, where whereSQL: String = "1", _ args: StatementArguments = [], includeDeleted: Bool = false) throws -> [Self] {
        let sql = selectSQL + " WHERE (\(whereSQL))" + (includeDeleted ? "" : " AND deleted_at IS NULL")
        return try Row.fetchAll(db, sql: sql, arguments: args).map(Self.init(row:))
    }
}

/// GRDB record wrapper for any stored model (`FetchableRecord` + `PersistableRecord`), e.g.
/// `try StoredRecord<Chore>.fetchAll(db)`. Repositories write through `StoreTx.save` instead so every write also
/// maintains the outbox and FTS index.
struct StoredRecord<Model: DatabaseModel>: FetchableRecord, PersistableRecord {
    var model: Model
    init(_ model: Model) { self.model = model }
    init(row: Row) throws { model = try Model(row: row) }
    static var databaseTableName: String { Model.recordType.tableName }
    func encode(to container: inout PersistenceContainer) throws {
        let cols = try model.columns()
        container["id"] = model.id.db
        for (k, v) in cols.values { container[k] = v }
    }
}

// MARK: - property / level / space / opening

extension Property: DatabaseModel {
    init(row: Row) throws {
        let line: String? = row["address_line"], locality: String? = row["locality"], region: String? = row["region"]
        let postal: String? = row["postal_code"], country: String? = row["country_code"]
        let hasAddress = [line, locality, region, postal, country].contains { $0 != nil }
        self.init(id: try row.uuid("id"), name: row["name"] ?? "My Home",
                  address: hasAddress ? PostalAddressLite(line: line, locality: locality, region: region, postalCode: postal, countryCode: country) : nil,
                  latitude: row["latitude"], longitude: row["longitude"], yearBuilt: row["year_built"], approxSqFt: row["approx_sq_ft"],
                  defaultLevelId: row.uuidOpt("default_level_id"), currencyCode: row["currency_code"] ?? "USD",
                  unitSystem: row.enumValue("unit_system"),
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("name", name)
        c.set("address_line", address?.line); c.set("locality", address?.locality); c.set("region", address?.region)
        c.set("postal_code", address?.postalCode); c.set("country_code", address?.countryCode)
        c.set("latitude", latitude); c.set("longitude", longitude); c.set("year_built", yearBuilt); c.set("approx_sq_ft", approxSqFt)
        c.set("default_level_id", uuid: defaultLevelId); c.set("currency_code", currencyCode)
        try c.set("unit_system", enum: unitSystem)
        c.setTimestamps(self)
        return c
    }
}

extension Level: DatabaseModel {
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), name: row["name"] ?? "", kind: row.enumValue("kind"),
                  sortOrder: row["sort_order"] ?? 0, underlayAttachmentId: row.uuidOpt("underlay_attachment_id"),
                  underlayTransform: try row.json("underlay_transform_json", UnderlayTransform.self),
                  underlayVisible: row.bool("underlay_visible"), georef: try row.json("georef_json", GeoReference.self),
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("name", name); try c.set("kind", enum: kind); c.set("sort_order", sortOrder)
        c.set("underlay_attachment_id", uuid: underlayAttachmentId); try c.set("underlay_transform_json", json: underlayTransform)
        c.set("underlay_visible", bool: underlayVisible); try c.set("georef_json", json: georef)
        c.setTimestamps(self)
        return c
    }
}

extension Space: DatabaseModel {
    static var derivedColumns: Set<String> { ["area_sq_in", "min_x", "min_y", "max_x", "max_y"] }
    init(row: Row) throws {
        guard let poly = try row.json("polygon_json", Polygon.self) else { throw RepositoryError.invalid("space without polygon") }
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), levelId: try row.uuid("level_id"), name: row["name"] ?? "",
                  spaceType: row.enumValue("space_type"), isExterior: row.bool("is_exterior"), polygon: poly, source: row.enumValue("source"),
                  isApproximate: row.bool("is_approximate"), colorHex: row["color_hex"], sortOrder: row["sort_order"] ?? 0,
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("level_id", uuid: levelId); c.set("name", name)
        try c.set("space_type", enum: spaceType); c.set("is_exterior", bool: isExterior); try c.set("polygon_json", json: polygon)
        try c.set("source", enum: source); c.set("is_approximate", bool: isApproximate); c.set("color_hex", colorHex); c.set("sort_order", sortOrder)
        Space.setDerived(&c, polygon)
        c.setTimestamps(self)
        return c
    }
    static func setDerived(_ c: inout Columns, _ polygon: Polygon) {
        let b = polygon.bounds
        let empty = polygon.vertices.isEmpty
        c.set("area_sq_in", polygon.area)
        c.set("min_x", empty ? 0 : b.minX); c.set("min_y", empty ? 0 : b.minY)
        c.set("max_x", empty ? 0 : b.maxX); c.set("max_y", empty ? 0 : b.maxY)
    }
}

extension Opening: DatabaseModel {
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), levelId: try row.uuid("level_id"),
                  spaceId: row.uuidOpt("space_id"), kind: row.enumValue("kind"),
                  segment: Segment(Vec2(x: row["ax"] ?? 0, y: row["ay"] ?? 0), Vec2(x: row["bx"] ?? 0, y: row["by"] ?? 0)),
                  heightIn: row["height_in"], sillIn: row["sill_in"], swing: row.enumOpt("swing"),
                  isExteriorDoor: row.bool("is_exterior_door"), source: row.enumValue("source"),
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("level_id", uuid: levelId); c.set("space_id", uuid: spaceId); try c.set("kind", enum: kind)
        c.set("ax", segment.a.x); c.set("ay", segment.a.y); c.set("bx", segment.b.x); c.set("by", segment.b.y)
        c.set("height_in", heightIn); c.set("sill_in", sillIn); try c.set("swing", enum: swing)
        c.set("is_exterior_door", bool: isExteriorDoor); try c.set("source", enum: source)
        c.setTimestamps(self)
        return c
    }
}

// MARK: - person / storage spot / measurement

extension Person: DatabaseModel {
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), name: row["name"] ?? "", colorHex: row["color_hex"],
                  sortOrder: row["sort_order"] ?? 0, createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("name", name); c.set("color_hex", colorHex); c.set("sort_order", sortOrder)
        c.setTimestamps(self)
        return c
    }
}

extension StorageSpot: DatabaseModel {
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), spaceId: try row.uuid("space_id"),
                  parentSpotId: row.uuidOpt("parent_spot_id"), name: row["name"] ?? "", ownerId: row.uuidOpt("owner_id"),
                  pin: row.vec("pin"), sortOrder: row["sort_order"] ?? 0,
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("space_id", uuid: spaceId); c.set("parent_spot_id", uuid: parentSpotId)
        c.set("name", name); c.set("owner_id", uuid: ownerId); c.set("pin", pin: pin); c.set("sort_order", sortOrder)
        c.setTimestamps(self)
        return c
    }
}

extension HomeMeasurement: DatabaseModel {
    init(row: Row) throws {
        var seg: Segment?
        if let ax: Double = row["seg_ax"], let ay: Double = row["seg_ay"], let bx: Double = row["seg_bx"], let by: Double = row["seg_by"] {
            seg = Segment(Vec2(x: ax, y: ay), Vec2(x: bx, y: by))
        }
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), label: row["label"] ?? "", kind: row.enumValue("kind"),
                  spaceId: row.uuidOpt("space_id"), openingId: row.uuidOpt("opening_id"), storageSpotId: row.uuidOpt("storage_spot_id"),
                  pin: row.vec("pin"), segment: seg,
                  dims: Dims3(width: row["width_in"], depth: row["depth_in"], height: row["height_in"]),
                  isDeliveryPath: row.bool("is_delivery_path"), note: row["note"], source: row.enumValue("source"),
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("label", label); try c.set("kind", enum: kind)
        c.set("space_id", uuid: spaceId); c.set("opening_id", uuid: openingId); c.set("storage_spot_id", uuid: storageSpotId)
        c.set("pin", pin: pin)
        c.set("seg_ax", segment?.a.x); c.set("seg_ay", segment?.a.y); c.set("seg_bx", segment?.b.x); c.set("seg_by", segment?.b.y)
        c.set("width_in", dims.width); c.set("depth_in", dims.depth); c.set("height_in", dims.height)
        c.set("is_delivery_path", bool: isDeliveryPath); c.set("note", note); try c.set("source", enum: source)
        c.setTimestamps(self)
        return c
    }
}

// MARK: - thing / chore / completion / calendar link

extension Thing: DatabaseModel {
    init(row: Row) throws {
        let currency: String = row["currency_code"] ?? "USD"
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), scope: try row.scope(), category: row.enumValue("category"),
                  name: row["name"] ?? "", ownership: row.enumValue("ownership"), templateKey: row["template_key"],
                  attributes: try row.json("attributes_json", [String: JSONValue].self) ?? [:],
                  brand: row["brand"], model: row["model"], serial: row["serial"], purchaseDate: row.localDateOpt("purchase_date"),
                  purchasePrice: (row["purchase_price_cents"] as Int64?).map { Money(cents: $0, currency: currency) },
                  warrantyEnd: row.localDateOpt("warranty_end"),
                  dims: Dims3(width: row["width_in"], depth: row["depth_in"], height: row["height_in"]),
                  fitMeasurementId: row.uuidOpt("fit_measurement_id"), pin: row.vec("pin"), notes: row["notes"],
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("scope", scope: scope); try c.set("category", enum: category)
        c.set("name", name); try c.set("ownership", enum: ownership); c.set("template_key", templateKey)
        try c.set("attributes_json", json: attributes)
        c.set("brand", brand); c.set("model", model); c.set("serial", serial); c.set("purchase_date", date: purchaseDate)
        c.set("purchase_price_cents", purchasePrice?.cents); c.set("currency_code", purchasePrice?.currency ?? "USD")
        c.set("warranty_end", date: warrantyEnd)
        c.set("width_in", dims.width); c.set("depth_in", dims.depth); c.set("height_in", dims.height)
        c.set("fit_measurement_id", uuid: fitMeasurementId); c.set("pin", pin: pin); c.set("notes", notes)
        c.setTimestamps(self)
        return c
    }
}

extension Chore: DatabaseModel {
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), scope: try row.scope(), title: row["title"] ?? "",
                  notes: row["notes"], assigneeId: row.uuidOpt("assignee_id"), repeatRule: try row.json("repeat_rule_json", RepeatRule.self),
                  startOn: try row.localDate("start_on"), nextDueOn: row.localDateOpt("next_due_on"), dueMinutes: row["due_minutes"],
                  remindEnabled: row.bool("remind_enabled"), remindOffsetMin: row["remind_offset_min"] ?? 0,
                  calendarEnabled: row.bool("calendar_enabled"), linkedThingId: row.uuidOpt("linked_thing_id"),
                  isPaused: row.bool("is_paused"), closedAt: row["closed_at"],
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("scope", scope: scope); c.set("title", title); c.set("notes", notes)
        c.set("assignee_id", uuid: assigneeId); try c.set("repeat_rule_json", json: repeatRule)
        c.set("start_on", date: startOn); c.set("next_due_on", date: nextDueOn); c.set("due_minutes", dueMinutes)
        c.set("remind_enabled", bool: remindEnabled); c.set("remind_offset_min", remindOffsetMin)
        c.set("calendar_enabled", bool: calendarEnabled); c.set("linked_thing_id", uuid: linkedThingId)
        c.set("is_paused", bool: isPaused); c.set("closed_at", closedAt)
        c.setTimestamps(self)
        return c
    }
}

extension ChoreCompletion: DatabaseModel {
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), choreId: try row.uuid("chore_id"),
                  dueOn: row.localDateOpt("due_on"), doneAt: row.date("done_at"), doneOn: try row.localDate("done_on"),
                  doneBy: row.uuidOpt("done_by"), outcome: row.enumValue("outcome"), note: row["note"],
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("chore_id", uuid: choreId); c.set("due_on", date: dueOn)
        c.set("done_at", doneAt); c.set("done_on", date: doneOn); c.set("done_by", uuid: doneBy)
        try c.set("outcome", enum: outcome); c.set("note", note)
        c.setTimestamps(self)
        return c
    }
}

extension ChoreCalendarLink: DatabaseModel {
    init(row: Row) throws {
        self.init(choreId: try row.uuid("chore_id"), propertyId: try row.uuid("property_id"), ownerDeviceId: row["owner_device_id"] ?? "",
                  calendarTitle: row["calendar_title"] ?? "", calendarSourceTitle: row["calendar_source_title"],
                  calendarIdentifier: row["calendar_identifier"], eventExternalId: row["event_external_id"],
                  eventMode: row.enumValue("event_mode"), seriesSignature: row["series_signature"],
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
        self.id = try row.uuid("id")
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("chore_id", uuid: choreId); c.set("owner_device_id", ownerDeviceId)
        c.set("calendar_title", calendarTitle); c.set("calendar_source_title", calendarSourceTitle)
        c.set("calendar_identifier", calendarIdentifier); c.set("event_external_id", eventExternalId)
        try c.set("event_mode", enum: eventMode); c.set("series_signature", seriesSignature)
        c.setTimestamps(self)
        return c
    }
}

// MARK: - project / cost line item / inventory / attachment

extension Project: DatabaseModel {
    init(row: Row) throws {
        let cur: String = row["currency_code"] ?? "USD"
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), scope: try row.scope(), title: row["title"] ?? "",
                  notes: row["notes"], status: row.enumValue("status"), priority: row["priority"],
                  estCost: (row["est_cost_cents"] as Int64?).map { Money(cents: $0, currency: cur) },
                  actualCost: (row["actual_cost_cents"] as Int64?).map { Money(cents: $0, currency: cur) },
                  estHours: row["est_hours"], actualHours: row["actual_hours"], targetOn: row.localDateOpt("target_on"),
                  startedOn: row.localDateOpt("started_on"), completedOn: row.localDateOpt("completed_on"), vendor: row["vendor"],
                  spawnedFromChoreId: row.uuidOpt("spawned_from_chore_id"), currencyCode: cur,
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("scope", scope: scope); c.set("title", title); c.set("notes", notes)
        try c.set("status", enum: status); c.set("priority", priority)
        c.set("est_cost_cents", estCost?.cents); c.set("actual_cost_cents", actualCost?.cents); c.set("currency_code", currencyCode)
        c.set("est_hours", estHours); c.set("actual_hours", actualHours); c.set("target_on", date: targetOn)
        c.set("started_on", date: startedOn); c.set("completed_on", date: completedOn); c.set("vendor", vendor)
        c.set("spawned_from_chore_id", uuid: spawnedFromChoreId)
        c.setTimestamps(self)
        return c
    }
}

extension CostLineItem: DatabaseModel {
    /// `cost_line_item` has no currency column; amounts use the project's currency.
    static var selectSQL: String {
        "SELECT cost_line_item.*, (SELECT p.currency_code FROM project p WHERE p.id = cost_line_item.project_id) AS _currency FROM cost_line_item"
    }
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), projectId: try row.uuid("project_id"),
                  label: row["label"] ?? "", amount: Money(cents: row["amount_cents"] ?? 0, currency: row["_currency"] ?? "USD"),
                  kind: row.enumValue("kind"), vendor: row["vendor"], incurredOn: row.localDateOpt("incurred_on"), hours: row["hours"],
                  receiptAttachmentId: row.uuidOpt("receipt_attachment_id"),
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); c.set("project_id", uuid: projectId); c.set("label", label)
        c.set("amount_cents", amount.cents); try c.set("kind", enum: kind); c.set("vendor", vendor)
        c.set("incurred_on", date: incurredOn); c.set("hours", hours); c.set("receipt_attachment_id", uuid: receiptAttachmentId)
        c.setTimestamps(self)
        return c
    }
}

extension InventoryItem: DatabaseModel {
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), kind: row.enumValue("kind"), name: row["name"] ?? "",
                  category: row["category"], ownerId: row.uuidOpt("owner_id"), scope: try row.scope(),
                  storageSpotId: row.uuidOpt("storage_spot_id"), quantity: row["quantity"] ?? 0, unit: row["unit"],
                  season: row.enumOpt("season"), inRotation: row.boolOpt("in_rotation"), expiresOn: row.localDateOpt("expires_on"),
                  isLow: row.bool("is_low"), lowThreshold: row["low_threshold"], linkedThingId: row.uuidOpt("linked_thing_id"),
                  notes: row["notes"], createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); try c.set("kind", enum: kind); c.set("name", name); c.set("category", category)
        c.set("owner_id", uuid: ownerId); c.set("scope", scope: scope); c.set("storage_spot_id", uuid: storageSpotId)
        c.set("quantity", quantity); c.set("unit", unit); try c.set("season", enum: season); c.set("in_rotation", bool: inRotation)
        c.set("expires_on", date: expiresOn); c.set("is_low", bool: isLow); c.set("low_threshold", lowThreshold)
        c.set("linked_thing_id", uuid: linkedThingId); c.set("notes", notes)
        c.setTimestamps(self)
        return c
    }
}

extension Attachment: DatabaseModel {
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), propertyId: try row.uuid("property_id"), ownerType: row.enumValue("owner_type"),
                  ownerId: try row.uuid("owner_id"), kind: row.enumValue("kind"), fileExt: row["file_ext"] ?? "", uti: row["uti"] ?? "",
                  byteSize: row["byte_size"] ?? 0, widthPx: row["width_px"], heightPx: row["height_px"], sha256: row["sha256"] ?? "",
                  caption: row["caption"], ocrText: row["ocr_text"], capturedAt: row["captured_at"],
                  createdAt: row.date("created_at"), updatedAt: row.date("updated_at"), deletedAt: row["deleted_at"])
    }
    func columns() throws -> Columns {
        var c = Columns()
        c.set("property_id", uuid: propertyId); try c.set("owner_type", enum: ownerType); c.set("owner_id", uuid: ownerId)
        try c.set("kind", enum: kind); c.set("file_ext", fileExt); c.set("uti", uti); c.set("byte_size", byteSize)
        c.set("width_px", widthPx); c.set("height_px", heightPx); c.set("sha256", sha256); c.set("caption", caption)
        c.set("ocr_text", ocrText); c.set("captured_at", capturedAt)
        c.setTimestamps(self)
        return c
    }
}

/// Model type for every record type (used by generic sync/purge code).
enum ModelTypes {
    static func type(for t: RecordType) -> any DatabaseModel.Type {
        switch t {
        case .property: return Property.self; case .level: return Level.self; case .space: return Space.self
        case .opening: return Opening.self; case .person: return Person.self; case .storageSpot: return StorageSpot.self
        case .measurement: return HomeMeasurement.self; case .thing: return Thing.self; case .chore: return Chore.self
        case .choreCompletion: return ChoreCompletion.self; case .choreCalendarLink: return ChoreCalendarLink.self
        case .project: return Project.self; case .costLineItem: return CostLineItem.self
        case .inventoryItem: return InventoryItem.self; case .attachment: return Attachment.self
        }
    }
}
