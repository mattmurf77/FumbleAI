import Foundation
import Testing
import HomeCore
import HomeCoreTesting

struct ProjectCSVTests {
    private func review(_ text: String, currency: String = "USD") throws -> [ProjectCSVReview] {
        let csv = try ProjectCSV(data: Data(text.utf8))
        return try csv.review(mapping: ProjectCSVMapping(csv), currency: currency)
    }

    @Test func excelQuotesMultilineBOMAndUnknownValues() throws {
        let rows = try review("\u{feff}Project,Year,Cost,Vendor,Notes\r\n\"Roof, garage\",2023,\"$1,200.07\",Jules,\"Said \"\"done\"\"\r\non site\"\r\nFan,,,,\r\n")
        let roof = try #require(rows.first?.item)
        #expect(roof.id == 2 && roof.title == "Roof, garage")
        #expect(roof.day == nil && roof.year == 2023 && roof.cost?.cents == 120007)
        #expect(roof.notes == "Said \"done\"\non site")
        #expect(rows[1].id == 4 && rows[1].item?.cost == nil && rows[1].item?.year == nil)
    }

    @Test func excelUTF16AndEuropeanFormats() throws {
        let input = "Project\tDate\tCost\tCurrency\r\nBoiler\t31/12/2020\t€1.234,50\tEUR\r\n"
        for (encoding, bom) in [(String.Encoding.utf16LittleEndian, [UInt8(0xff), 0xfe]), (.utf16BigEndian, [0xfe, 0xff])] {
            let csv = try ProjectCSV(data: Data(bom) + (try #require(input.data(using: encoding))))
            var mapping = ProjectCSVMapping(csv)
            mapping.dayFirst = true; mapping.decimalComma = true
            let row = try #require(try csv.review(mapping: mapping, currency: "EUR").first?.item)
            #expect(csv.separator == 9 && row.day == LocalDate(2020, 12, 31) && row.cost?.cents == 123450)
        }
        #expect(try review("sep=;\r\nProject;Cost\r\nFence;0.00").first?.item?.cost?.cents == 0)
    }

    @Test func manuallyLoggedYearNeverBecomesAnExactDay() {
        let draft = ProjectDraft(propertyId: UUID(), scope: .property, title: "Insulation", status: .done, completedYear: 2019)
        let project = ProjectLogic.make(from: draft, now: .now, today: .init(2026, 11, 4))
        #expect(project.completedYear == 2019 && project.completedOn == nil)
        let preserved = ProjectLogic.setStatus(project, .done, today: .init(2026, 11, 4))
        #expect(preserved.completedYear == 2019 && preserved.completedOn == nil)
        let actual = ProjectLogic.markDone(project, actual: nil, completedOn: .init(2019, 3, 4), hours: nil)
        #expect(actual.completedYear == nil && actual.completedOn == LocalDate(2019, 3, 4))
    }

    @Test func templateRoundTripAndNativeCompletedProjectExport() throws {
        let example = try ProjectCSV(data: ProjectCSV.sample(currency: "CAD"))
        let mapped = try example.review(mapping: .init(example), currency: "CAD")
        #expect(mapped.count == 2 && mapped.allSatisfy { $0.item != nil })
        #expect(mapped[0].item?.year == 2022)
        let id = UUID()
        let csv = "id,title,status,actual_cost,spent_effective,currency,completed_on,vendor,work_action\n\(id),Patio,done,,23.10,CAD,2022,Kai,installed\n\(UUID()),Roof,planned,,0,CAD,,,\n\(UUID()),Fan,done,,0.00,CAD,,,"
        let rows = try review(csv, currency: "CAD")
        #expect(rows[0].item?.sourceID == id && rows[0].item?.cost?.cents == 2310)
        #expect(rows[0].item?.action == .installed)
        #expect(rows[1].issue != nil)
        #expect(rows[2].item != nil && rows[2].item?.cost == nil)
    }

    @Test func invalidRowsCanBeSkippedAndColumnsRemapped() throws {
        let csv = try ProjectCSV(data: Data("What,when,actual cost,currency\nTile,2023-02-29,100.001,USD\nRoof,2020,5,EUR\nDoor,2024-02-29,0.50,USD\nSiding,2020,ABC,USD".utf8))
        var m = ProjectCSVMapping(csv)
        #expect(throws: ProjectCSVError.self) { try csv.review(mapping: m, currency: "USD") }
        m.columns[.title] = 0; m.columns[.date] = 1
        let rows = try csv.review(mapping: m, currency: "USD")
        #expect(rows.compactMap(\.item).count == 1 && rows[2].item?.cost?.cents == 50)
        #expect(rows[1].issue?.contains("EUR") == true)
        m.columns[.notes] = 0
        #expect(throws: ProjectCSVError.self) { try csv.review(mapping: m, currency: "USD") }
    }

    @Test func rejectsMalformedAndOversizeInput() throws {
        for text in ["", "Title", "Title\n\"unclosed", "Title,Notes\nTile,\"ok\"oops", "Title\n" + String(repeating: "a", count: 32769)] {
            #expect(throws: ProjectCSVError.self) { try ProjectCSV(data: Data(text.utf8)) }
        }
        #expect(throws: ProjectCSVError.self) { try ProjectCSV(data: Data([0x80, 0x00])) }
        #expect(throws: ProjectCSVError.self) { try ProjectCSV(data: Data(repeating: 65, count: ProjectCSV.maxBytes + 1)) }
        #expect(try review("Title,Cost\nTile,12,00").first?.issue != nil)
        #expect(try review("Title,Cost\nRoof,9999999999999999999999").first?.issue != nil)
    }

    @Test func demoRepositoryPreservesEditsAndReportsDuplicateAndConflict() async throws {
        let property = Property()
        var snap = InMemorySnapshot()
        snap.properties[property.id] = property
        let repository = InMemoryProjectRepository(store: InMemoryStore(snap))
        let source = try review("Title,Year,Cost\nRoof,2020,9.99\nRoof,2020,9.99\nRoof,2020,10.40").compactMap(\.item)
        let reviewed = try await repository.reviewCSVImport(source, propertyID: property.id)
        #expect(reviewed[0].disposition == .ready && reviewed[1].disposition == .duplicate)
        if case .conflict = reviewed[2].disposition {} else { Issue.record("Changed same-title/date row must be shown as a conflict") }
        _ = try await repository.importCompletedCSV(source, propertyID: property.id)
        let projects = try await repository.projects(.past(property.id))
        #expect(projects.count == 1 && projects[0].completedYear == 2020 && projects[0].completedOn == nil)
        var changed = projects[0]; changed.title = "Owner edited project"
        try await repository.update(changed)
        #expect(try await repository.importCompletedCSV([source[0]], propertyID: property.id).first?.disposition == .duplicate)
    }
}
