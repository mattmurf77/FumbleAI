import Foundation
import Testing
import HomeCore

struct HomeRecommendationTests {
    private let today = LocalDate(2026, 11, 4)
    private let now = Date(timeIntervalSince1970: 1_798_761_600)
    private func chore(_ home: Property, _ name: String, days: Int?, minutes: Int? = nil) -> Chore {
        Chore(propertyId: home.id, scope: .property, title: name, startOn: today.adding(days: -30),
              nextDueOn: days.map { today.adding(days: $0) }, dueMinutes: minutes)
    }
    private func recs(_ context: HomeRecommendationContext, hidden: Set<String> = []) -> [HomeRecommendation] {
        HomeRecommendations.ranked(context, today: today, now: now, hidden: hidden)
    }

    @Test func realChoresWinAndTieBreaksAreStable() throws {
        let home = Property()
        var ctx = HomeRecommendationContext(property: home)
        let early = chore(home, "Water heater", days: -2, minutes: 480)
        let later = chore(home, "Other overdue", days: -2, minutes: 800)
        let due = chore(home, "Today", days: 0)
        var paused = chore(home, "Paused", days: -20); paused.isPaused = true
        var closed = chore(home, "Done", days: -20); closed.closedAt = now
        var trashed = chore(home, "Removed", days: -20); trashed.deletedAt = now
        let foreign = chore(Property(), "Other home", days: -30)
        ctx.chores = [due, later, paused, closed, early, foreign, trashed]
        ctx.projects = [Project(propertyId: home.id, scope: .property, title: "Fence", status: .planned)]
        #expect(Array(recs(ctx).prefix(3)).map(\.action) == [.chore(early.id), .chore(later.id), .chore(due.id)])
        ctx.chores.reverse()
        #expect(recs(ctx).first?.action == .chore(early.id))
        let key = try #require(recs(ctx).first?.id)
        #expect(recs(ctx, hidden: [key]).first?.action == .chore(later.id))
        var rescheduled = early; rescheduled.nextDueOn = today
        ctx.chores = [rescheduled]
        #expect(recs(ctx, hidden: [key]).first?.action == .chore(early.id))
    }

    @Test func usefulFirstRecordAndReversiblePropertyScopedHiding() {
        let home = Property()
        var ctx = HomeRecommendationContext(property: home)
        #expect(recs(ctx).map(\.action) == [.firstRecord, .setupPlan])
        #expect(recs(ctx, hidden: ["first-record"]).map(\.action) == [.setupPlan])
        #expect(recs(ctx).first?.action == .firstRecord)
        #expect(HomeRecommendations.preferenceKey(propertyID: home.id) != HomeRecommendations.preferenceKey(propertyID: UUID()))
        ctx.hasInteriorLevel = true; ctx.documentCount = 1
        #expect(recs(ctx).isEmpty)
        ctx.documentCount = 0; ctx.previouslyUsed = true
        #expect(recs(ctx).isEmpty)
    }

    @Test func seasonsRequireRecordedEquipmentAndSuppressDuplicatedTasks() {
        var home = Property(); home.latitude = 42
        var ctx = HomeRecommendationContext(property: home)
        let furnace = Thing(propertyId: home.id, scope: .property, category: .system, name: "Basement furnace", templateKey: "hvac_furnace")
        let cooling = Thing(propertyId: home.id, scope: .property, category: .system, name: "Air conditioner")
        let dryer = Thing(propertyId: home.id, scope: .property, category: .appliance, name: "Ventless dryer")
        ctx.things = [furnace, cooling, dryer]; ctx.hasInteriorLevel = true
        #expect(recs(ctx).first?.action == .maintenance(.furnace))
        #expect(!recs(ctx).contains { $0.action == .maintenance(.cooling) || $0.action == .maintenance(.dryer) })
        var filter = chore(home, "Replace filter", days: 60); filter.linkedThingId = furnace.id
        var serviced = chore(home, "Furnace service", days: nil); serviced.closedAt = now.addingTimeInterval(-10 * 86_400)
        ctx.chores = [filter, serviced]
        #expect(!recs(ctx).contains { $0.action == .maintenance(.filter) || $0.action == .maintenance(.furnace) })
        let homeIdeas = HomeRecommendations.maintenanceCatalog(ctx, today: today, now: now)
        #expect(!homeIdeas.contains(.filter) && !homeIdeas.contains(.furnace))
        #expect(homeIdeas.contains(.closet))
        home.latitude = -34
        var south = HomeRecommendationContext(property: home); south.things = [cooling, furnace]
        #expect(recs(south).first?.action == .maintenance(.cooling))
        home.latitude = nil
        var unknown = HomeRecommendationContext(property: home); unknown.things = [cooling]
        #expect(!recs(unknown).contains { $0.action == .maintenance(.cooling) })
    }

    @Test func projectMatchesActOnMissingBudgetOrQuoteAndRespectAnExplicitZero() {
        let home = Property()
        var ctx = HomeRecommendationContext(property: home)
        var project = Project(propertyId: home.id, scope: .property, title: "Fence", status: .planned)
        ctx.projects = [project]; ctx.hasInteriorLevel = true
        #expect(recs(ctx).first?.action == .planProject(project.id))
        ctx.quotedProjects.insert(project.id)
        #expect(recs(ctx).first?.reason.contains("quote is on file") == true)
        project.estCost = .init(cents: 25000)
        ctx.projects = [project]
        #expect(recs(ctx).isEmpty)
        ctx.quotedProjects = []
        #expect(recs(ctx).first?.id.hasSuffix("-quote") == true)
        project.estCost = .zero("USD")
        ctx.projects = [project]
        #expect(recs(ctx).isEmpty)
        project.status = .done; project.estCost = nil
        ctx.projects = [project]
        #expect(recs(ctx).isEmpty)
    }

    @Test func realWarrantyWindowAndDistinctCatalog() {
        let home = Property()
        var ctx = HomeRecommendationContext(property: home)
        var item = Thing(propertyId: home.id, scope: .property, category: .appliance, name: "Fridge", warrantyEnd: today.adding(days: 9))
        ctx.things = [item]; ctx.hasInteriorLevel = true
        #expect(recs(ctx).first?.action == .reviewWarranty(item.id))
        item.ownership = .planned; ctx.things = [item]
        #expect(recs(ctx).isEmpty)
        ctx.projects = [Project(propertyId: home.id, scope: .property, title: MaintenanceIdea.closet.title, status: .planned)]
        let all = HomeRecommendations.maintenanceCatalog(ctx, today: today, now: now, hidden: ["dryer"])
        #expect(!all.contains(.closet) && !all.contains(.dryer) && Set(all).count == all.count)
    }
}
