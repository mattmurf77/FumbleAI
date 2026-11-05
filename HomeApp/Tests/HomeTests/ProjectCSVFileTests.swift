import Foundation
import XCTest
import HomeCore
@testable import Home

final class ProjectCSVFileTests: XCTestCase {
    func testFileProviderReadUsesTheSameBytesAsOpenIn() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: file) }
        let sample = ProjectCSV.sample(currency: "USD")
        try sample.write(to: file)
        let picked = try ProjectCSVFile.read(file)
        let handedOff = ProjectCSVFile(name: file.lastPathComponent, data: sample)
        XCTAssertEqual(picked.name, handedOff.name)
        XCTAssertEqual(picked.data, handedOff.data)
        XCTAssertEqual(try ProjectCSV(data: picked.data).rows.count, 2)
        try Data(repeating: 32, count: ProjectCSVFile.maxBytes + 1).write(to: file)
        XCTAssertThrowsError(try ProjectCSVFile.read(file))
    }
}
