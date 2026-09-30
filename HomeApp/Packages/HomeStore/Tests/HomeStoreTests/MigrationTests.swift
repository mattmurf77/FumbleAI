import Foundation
import XCTest
import GRDB
@testable import HomeStore

final class MigrationTests: XCTestCase {
    func testOutdoorMigrationKeepsThingsAndAllowsOutdoorCategory() throws {
        let q = try DatabaseQueue(configuration: AppDatabase.configuration())
        try Migrations.migrator.migrate(q, upTo: Migrations.v1Search)
        let now = "2026-09-29 12:00:00.000"
        try q.write { db in
            try db.execute(sql: "INSERT INTO property (id, created_at, updated_at) VALUES ('p1', ?, ?)", arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO thing (id, property_id, scope, category, name, template_key, created_at, updated_at)
                VALUES ('t1', 'p1', 'property', 'appliance', 'Fridge', 'refrigerator', ?, ?)
                """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO chore (id, property_id, scope, title, start_on, linked_thing_id, created_at, updated_at)
                VALUES ('c1', 'p1', 'property', 'Clean coils', '2026-09-29', 't1', ?, ?)
                """, arguments: [now, now])
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO thing (id, property_id, scope, category, name, created_at, updated_at)
                VALUES ('t0', 'p1', 'property', 'outdoor', 'Oak', ?, ?)
                """, arguments: [now, now]))
        }

        try Migrations.migrator.migrate(q)

        try q.write { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT name FROM thing"), ["Fridge"])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT linked_thing_id FROM chore WHERE id = 'c1'"), "t1")
            try db.execute(sql: """
                INSERT INTO thing (id, property_id, scope, category, name, template_key, created_at, updated_at)
                VALUES ('t2', 'p1', 'property', 'outdoor', 'Oak', 'tree', ?, ?)
                """, arguments: [now, now])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thing WHERE category = 'outdoor'"), 1)
            let indexes = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'thing' AND sql IS NOT NULL")
            XCTAssertEqual(Set(indexes), ["thing_space", "thing_level", "thing_template"])
            XCTAssertEqual(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count, 0)
            let fk = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(chore)").map { $0["table"] as String }
            XCTAssertTrue(fk.contains("thing"))
            // chore still cascades SET NULL through the rebuilt table.
            try db.execute(sql: "DELETE FROM thing WHERE id = 't1'")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT linked_thing_id FROM chore WHERE id = 'c1'"))
        }
    }
}
