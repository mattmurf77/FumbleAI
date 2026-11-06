import Foundation
import HomeCore
import Testing
@testable import Home

struct HomeCatalogResourceTests {
    @Test @MainActor func offlineGuidesUseTheValidatedBundledCatalog() throws {
        let url = try #require(Bundle.main.url(forResource: "home-catalog", withExtension: "json"))
        let catalog = try HomeContentCatalog.decode(Data(contentsOf: url))
        let environment = AppEnvironment(.inMemory(sample: true))
        #expect(environment.catalog.snapshot == catalog)
        #expect(environment.catalog.guide(.filter, mode: .hirePro)?.unit == "hour")
        #expect(environment.catalog.resale(.gutters, mode: .hirePro) == nil)
        #expect(environment.catalog.resale(.closet, mode: .diy) == nil)
        #expect(environment.catalog.supplies(.filter).map(\.name) == ["Replacement HVAC filter", "Flashlight"])
    }
}
