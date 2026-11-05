import Foundation

public struct ProjectCSVError: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Parses spreadsheet text without evaluating formulas. The row number points to the original physical line.
public struct ProjectCSV: Sendable {
    public static let maxBytes = 4 * 1024 * 1024
    public static let maxRows = 2000
    public struct Row: Identifiable, Sendable {
        public let id: Int
        public let cells: [String]
    }
    public let headers: [String]
    public let rows: [Row]
    public let separator: UInt8

    public static func sample(currency: String) -> Data {
        let rows = ["Project title,Completion date or year,Actual cost,Currency,Contractor,Work type,Notes",
                    "Replace kitchen flooring,2022,1250.75,\(currency),,Replaced,Materials and labor",
                    "Service furnace,2024-10-15,,\(currency),,Serviced,"]
        return Data(("\u{feff}" + rows.joined(separator: "\r\n") + "\r\n").utf8)
    }

    public init(data: Data) throws {
        guard data.count <= Self.maxBytes else { throw ProjectCSVError("Choose a file of 4 MB or less.") }
        let text: String?
        if data.starts(with: [0xff, 0xfe]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xfe, 0xff]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...], encoding: .utf8) }
        guard let text, !text.utf8.contains(0) else { throw ProjectCSVError("Save the sheet as CSV UTF-8 or Unicode text in Excel.") }
        let bytes = Array(text.utf8)
        var start = 0
        var firstLine = 1
        var explicit: UInt8?
        if bytes.count >= 6, String(decoding: bytes.prefix(4), as: UTF8.self).lowercased() == "sep=",
           [9, 44, 59].contains(bytes[4]), [10, 13].contains(bytes[5]) {
            explicit = bytes[4]
            start = bytes[5] == 13 && bytes.count > 6 && bytes[6] == 10 ? 7 : 6
            firstLine = 2
        }
        let delimiter = explicit ?? Self.detect(bytes.dropFirst(start))
        separator = delimiter
        var all: [Row] = [], cells: [String] = [], field: [UInt8] = []
        var i = start, line = firstLine, rowLine = firstLine
        var quoted = false, afterQuote = false
        func endField() throws {
            guard cells.count < 96 else { throw ProjectCSVError("Row \(rowLine) exceeds 96 columns.") }
            cells.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            afterQuote = false
        }
        func endRow() throws {
            try endField()
            if cells.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                guard all.count <= Self.maxRows else { throw ProjectCSVError("Split the sheet into files of up to 2,000 data rows each.") }
                all.append(Row(id: rowLine, cells: cells))
            }
            cells.removeAll(keepingCapacity: true)
        }
        while i < bytes.count {
            let ch = bytes[i]
            if ch == 10 || ch == 13 {
                if ch == 13 && i + 1 < bytes.count && bytes[i + 1] == 10 { i += 1 }
                if quoted { field.append(10) } else { try endRow(); rowLine = line + 1 }
                line += 1
            } else if quoted {
                if ch == 34 {
                    if i + 1 < bytes.count && bytes[i + 1] == 34 { field.append(34); i += 1 }
                    else { quoted = false; afterQuote = true }
                } else { field.append(ch) }
            } else if ch == delimiter { try endField() }
            else if ch == 34 && field.isEmpty && !afterQuote { quoted = true }
            else if afterQuote || ch == 34 { throw ProjectCSVError("Check the quotation marks on row \(rowLine).") }
            else { field.append(ch) }
            guard field.count <= 32_768 else { throw ProjectCSVError("A cell on row \(rowLine) exceeds 32 KB.") }
            i += 1
        }
        guard !quoted else { throw ProjectCSVError("Close the quoted cell starting on row \(rowLine).") }
        try endRow()
        guard all.count > 1 else { throw ProjectCSVError("Include a header and at least one data row.") }
        headers = all[0].cells
        rows = Array(all.dropFirst())
    }

    private static func detect(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var counts: [UInt8: Int] = [:], quoted = false
        for byte in bytes {
            if byte == 34 { quoted.toggle() }
            if quoted { continue }
            if byte == 10 || byte == 13 { break }
            if byte == 9 || byte == 44 || byte == 59 { counts[byte, default: 0] += 1 }
        }
        return [UInt8(44), 9, 59].max { counts[$0, default: 0] < counts[$1, default: 0] } ?? 44
    }
}

public enum ProjectCSVField: String, CaseIterable, Identifiable, Sendable {
    case title = "Project title", date = "Completion date or year", cost = "Actual cost", vendor = "Contractor",
         action = "Work type", notes = "Notes", currency = "Currency"
    public var id: Self { self }
    fileprivate var names: [String] {
        switch self {
        case .title: return ["title", "projecttitle", "projectname", "project", "improvement", "upgrade", "description", "workcompleted"]
        case .date: return ["completedon", "completiondate", "datecompleted", "completed", "date", "year", "completionyear", "dateoryear", "completiondateoryear"]
        case .cost: return ["actualcost", "totalcost", "cost", "amountpaid", "amount", "paid"]
        case .vendor: return ["vendor", "contractor", "provider", "company"]
        case .action: return ["workaction", "worktype", "typeofwork", "action"]
        case .notes: return ["notes", "note", "details", "comments"]
        case .currency: return ["currency", "currencycode"]
        }
    }
}

public struct ProjectCSVMapping: Sendable {
    public var columns: [ProjectCSVField: Int] = [:]
    public var dayFirst: Bool
    public var decimalComma: Bool
    public init(_ file: ProjectCSV) {
        let normalized = file.headers.map(Self.normalize)
        for field in ProjectCSVField.allCases {
            columns[field] = field.names.lazy.compactMap { normalized.firstIndex(of: $0) }.first
        }
        dayFirst = false
        decimalComma = false
    }
    fileprivate static func normalize(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
}

public struct ProjectCSVItem: Hashable, Sendable, Identifiable {
    public var id: Int
    public var sourceID: UUID?
    public var title: String
    public var day: LocalDate?
    public var year: Int?
    public var cost: Money?
    public var vendor: String?
    public var action: Project.WorkAction?
    public var notes: String?

    public init(row: Int, sourceID: UUID? = nil, title: String, day: LocalDate? = nil, year: Int? = nil,
                cost: Money? = nil, vendor: String? = nil, action: Project.WorkAction? = nil, notes: String? = nil) {
        id = row; self.sourceID = sourceID; self.title = title; self.day = day; self.year = year
        self.cost = cost; self.vendor = vendor; self.action = action; self.notes = notes
    }

    public func validate(currency: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 300 else {
            throw ProjectCSVError("Enter a project title of up to 300 characters.")
        }
        guard (day == nil || year == nil), year.map({ (1...9999).contains($0) }) ?? true,
              day.map({ (1...9999).contains($0.year) }) ?? true else { throw ProjectCSVError("Check the completion date.") }
        guard cost.map({ $0.currency == currency && (0...100_000_000_000).contains($0.cents) }) ?? true else {
            throw ProjectCSVError("Enter a nonnegative amount up to 1 billion in \(currency).")
        }
        guard (vendor?.count ?? 0) <= 300, (notes?.count ?? 0) <= 8000, action != .unknown else {
            throw ProjectCSVError("Check the work type, contractor (300 characters) and notes (8,000 characters).")
        }
    }

    /// Length-prefixing preserves field boundaries, including multiline descriptions. HomeStore hashes this.
    public var signature: String {
        let values = [title, day?.description, year.map(String.init), cost?.plainString, cost?.currency, vendor, action?.rawValue, notes]
        return values.map { $0.map { "\($0.utf8.count):\($0)" } ?? "-" }.joined()
    }

    public func makeProject(property: Property, now: Date) -> Project {
        Project(id: sourceID ?? UUID(), propertyId: property.id, scope: .property, title: title, notes: notes,
                status: .done, workAction: action, actualCost: cost, completedOn: day, completedYear: year,
                vendor: vendor, currencyCode: property.currencyCode, createdAt: now, updatedAt: now)
    }
}

public struct ProjectCSVReview: Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var item: ProjectCSVItem?
    public var issue: String?
}

public extension ProjectCSV {
    func review(mapping: ProjectCSVMapping, currency: String) throws -> [ProjectCSVReview] {
        guard mapping.columns[.title] != nil else { throw ProjectCSVError("Choose the column containing project titles.") }
        guard Set(mapping.columns.values).count == mapping.columns.count, mapping.columns.values.allSatisfy(headers.indices.contains) else {
            throw ProjectCSVError("Assign each spreadsheet column to one field only.")
        }
        let normalized = headers.map(ProjectCSVMapping.normalize)
        let native = ["id", "title", "status", "spenteffective", "currency"].allSatisfy(normalized.contains)
        return rows.map { row in
            func cell(_ index: Int?) -> String? {
                guard let index, row.cells.indices.contains(index) else { return nil }
                let s = row.cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            func mapped(_ f: ProjectCSVField) -> String? { cell(mapping.columns[f]) }
            let title = mapped(.title) ?? ""
            do {
                guard row.cells.count <= headers.count else { throw ProjectCSVError("More values than headers. Check the delimiter or quoted amounts.") }
                var source: UUID?
                if native {
                    guard cell(normalized.firstIndex(of: "status")) == "done" else { throw ProjectCSVError("This exported project is not completed.") }
                    guard let raw = cell(normalized.firstIndex(of: "id")), let uuid = UUID(uuidString: raw) else { throw ProjectCSVError("Invalid exported project ID.") }
                    source = uuid
                }
                let statedCurrency = native ? cell(normalized.firstIndex(of: "currency")) : mapped(.currency)
                if let code = statedCurrency, code.uppercased() != currency.uppercased() { throw ProjectCSVError("Currency \(code) differs from this home’s \(currency).") }
                let (day, year) = try Self.date(mapped(.date), dayFirst: mapping.dayFirst)
                var money = try Self.amount(mapped(.cost), currency: currency, decimalComma: mapping.decimalComma)
                if native, money == nil, mapping.columns[.cost] == normalized.firstIndex(of: "actualcost"),
                   let fallback = try Self.amount(cell(normalized.firstIndex(of: "spenteffective")), currency: currency, decimalComma: false), fallback.cents > 0 {
                    money = fallback
                }
                let action = try Self.action(mapped(.action))
                let item = ProjectCSVItem(row: row.id, sourceID: source, title: title, day: day, year: year, cost: money,
                                          vendor: mapped(.vendor), action: action, notes: mapped(.notes))
                try item.validate(currency: currency)
                return .init(id: row.id, title: title, item: item, issue: nil)
            } catch { return .init(id: row.id, title: title, item: nil, issue: error.localizedDescription) }
        }
    }

    private static func date(_ raw: String?, dayFirst: Bool) throws -> (LocalDate?, Int?) {
        guard let raw else { return (nil, nil) }
        if raw.count == 4, raw.allSatisfy(\.isNumber), let y = Int(raw), (1...9999).contains(y) { return (nil, y) }
        if let d = LocalDate(string: raw), d.year > 0 { return (d, nil) }
        let a = raw.split(separator: "/", omittingEmptySubsequences: false)
        if a.count == 3, a[2].count == 4, let y = Int(a[2]), let first = Int(a[0]), let second = Int(a[1]) {
            let m = dayFirst ? second : first, d = dayFirst ? first : second
            if y > 0, (1...12).contains(m), (1...LocalDate.daysInMonth(year: y, month: m)).contains(d) { return (.init(y, m, d), nil) }
        }
        throw ProjectCSVError("Use a four-digit year, YYYY-MM-DD, or a slash date with a four-digit year.")
    }

    private static func action(_ raw: String?) throws -> Project.WorkAction? {
        guard let raw else { return nil }
        let names: [String: Project.WorkAction] = ["service": .serviced, "serviced": .serviced, "maintenance": .serviced,
            "repair": .repaired, "repaired": .repaired, "replacement": .replaced, "replaced": .replaced,
            "installation": .installed, "installed": .installed, "newlyinstalled": .installed, "remodel": .remodeled, "remodeled": .remodeled]
        guard let action = names[ProjectCSVMapping.normalize(raw)] else { throw ProjectCSVError("Unrecognized work type. Map this column to Notes or skip the row.") }
        return action
    }

    private static func amount(_ raw: String?, currency: String, decimalComma: Bool) throws -> Money? {
        guard var s = raw else { return nil }
        let code = currency.uppercased()
        if s.uppercased().hasPrefix(code) { s = String(s.dropFirst(code.count)).trimmingCharacters(in: .whitespaces) }
        if s.uppercased().hasSuffix(code) { s = String(s.dropLast(code.count)).trimmingCharacters(in: .whitespaces) }
        let symbols = ["USD":"$", "CAD":"$", "AUD":"$", "NZD":"$", "EUR":"€", "GBP":"£"]
        if let mark = symbols[code], s.hasPrefix(mark) { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let decimal: Character = decimalComma ? "," : "."
        let group: Character = decimalComma ? "." : ","
        let parts = s.split(separator: decimal, omittingEmptySubsequences: false)
        let invalid = ProjectCSVError("Check the amount, currency and decimal format. Use up to two decimal places.")
        guard (1...2).contains(parts.count) else { throw invalid }
        let groups = parts[0].split(separator: group, omittingEmptySubsequences: false)
        let digits: (Substring) -> Bool = { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
        guard !groups.isEmpty, groups.allSatisfy(digits), groups.count == 1 || (groups[0].count <= 3 && groups.dropFirst().allSatisfy { $0.count == 3 }),
              let whole = Int64(groups.joined()), whole <= 1_000_000_000 else { throw invalid }
        let fraction = parts.count == 2 ? parts[1] : ""
        guard parts.count == 1 || (digits(fraction) && fraction.count <= 2) else { throw invalid }
        let cents = Int64(fraction) ?? 0
        return Money(cents: whole * 100 + (fraction.count == 1 ? cents * 10 : cents), currency: currency)
    }
}
