import Foundation
import Observation
import PlanKit
import HomeCore
import PlanCanvas

/// Loads everything the home screen shows and keeps the canvas render model current.
///
/// Observations (each yields immediately, then after every relevant commit):
/// - current property → levels (pills) → the selected level's `LevelGeometry` and `LensStats`.
/// Geometry changes rebuild the whole `LevelRenderModel` off the main actor; lens/stats changes only rebuild the
/// lens decorations (LLD §7.2).
@MainActor
@Observable
final class PlanScreenModel {
    private(set) var property: Property?
    private(set) var levels: [Level] = []
    private(set) var levelId: UUID?
    private(set) var geometry: LevelGeometry?
    private(set) var stats: LensStats?
    private(set) var model: LevelRenderModel = .empty()
    private(set) var loaded = false
    private(set) var propertySummary: PropertySummary?
    private(set) var settings = AppSettings()
    var lens: LensID = .plan
    /// One-shot floor request (the home hub's "Yard & Exterior" card): used instead of the default floor when the
    /// levels first load, then cleared.
    var preferredLevelId: UUID?

    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var geometryVersion = 0

    var level: Level? { levels.first { $0.id == levelId } }
    var unitSystem: UnitSystem { property?.unitSystem ?? .imperial }

    /// Runs for the lifetime of the screen (`.task`). Cancelling the task ends every observation.
    func run(env: AppEnvironment) async {
        lens = env.selectedLens
        settings = await env.settings.load()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await s in env.settings.observe() { self.settings = s }
            }
            group.addTask { @MainActor in
                for await p in env.plan.observeCurrentProperty() {
                    let changed = p?.id != self.property?.id
                    self.property = p
                    self.loaded = true
                    if changed { self.observeLevels(env: env) }
                }
            }
        }
        levelTask?.cancel()
        levelsTask?.cancel()
        levelTask = nil
    }

    @ObservationIgnored private var levelsTask: Task<Void, Never>?

    private func observeLevels(env: AppEnvironment) {
        levelsTask?.cancel()
        guard let pid = property?.id else { levels = []; levelId = nil; return }
        levelsTask = Task { @MainActor in
            for await ls in env.plan.observeLevels(property: pid) {
                let sorted = ls.filter { $0.deletedAt == nil }.sortedForPills
                self.levels = sorted
                if self.levelId == nil || !sorted.contains(where: { $0.id == self.levelId }) {
                    // Cold launch / deleted level: the property's default floor (FR-CNV-13/14).
                    let requested = self.preferredLevelId.flatMap { id in sorted.first { $0.id == id } }
                    if requested != nil { self.preferredLevelId = nil }
                    if let l = requested ?? sorted.defaultLevel(preferred: self.property?.defaultLevelId) { self.select(level: l.id, env: env) }
                }
                await self.refreshPropertySummary(env: env)
            }
        }
    }

    /// Switches floors (pills only, decision #12): observes that level's geometry and lens stats.
    func select(level id: UUID, env: AppEnvironment) {
        guard id != levelId || levelTask == nil else { return }
        levelId = id
        geometry = nil
        stats = nil
        levelTask?.cancel()
        let today = env.clock.today
        levelTask = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    for await g in env.plan.observeGeometry(level: id) {
                        guard self.levelId == id else { return }
                        self.geometry = g
                        await self.rebuildGeometry()
                        await self.refreshPropertySummary(env: env)
                    }
                }
                group.addTask { @MainActor in
                    for await s in env.lensStats.observeStats(level: id, today: today) {
                        guard self.levelId == id else { return }
                        self.stats = s
                        self.rebuildLens()
                    }
                }
            }
        }
        Task { @MainActor in
            var s = await env.settings.load()
            if s.lastLevelId != id { s.lastLevelId = id; await env.settings.save(s) }
        }
    }

    func setLens(_ l: LensID, env: AppEnvironment) {
        guard l != lens else { return }
        lens = l
        env.selectedLens = l
        rebuildLens()
        Task { @MainActor in
            var s = await env.settings.load()
            if s.lastLens != l { s.lastLens = l; await env.settings.save(s) }
        }
    }

    // MARK: Render model

    private var context: LensContext {
        LensContext(levelName: level?.name ?? "", isExterior: level?.isExterior ?? false, unitSystem: unitSystem,
                    currency: property?.currencyCode ?? "USD", property: propertySummary)
    }

    private func rebuildGeometry() async {
        guard let g = geometry else { return }
        geometryVersion += 1
        let version = geometryVersion
        let unit = unitSystem
        let built = await Task.detached(priority: .userInitiated) {
            RenderModelBuilder.geometry(g, unitSystem: unit)
        }.value
        guard version == geometryVersion else { return }   // a newer geometry arrived meanwhile
        model = LevelRenderModel(geometry: built,
                                 lens: RenderModelBuilder.decorations(lens: lens, stats: stats, geometry: built, context: context),
                                 version: model.version + 1)
    }

    func rebuildLens() {
        guard geometry != nil else { return }
        model = RenderModelBuilder.rebuildingLens(model, lens: lens, stats: stats, context: context)
    }

    private func refreshPropertySummary(env: AppEnvironment) async {
        guard let p = property else { return }
        let spaces = (try? await env.plan.spaces(property: p.id)) ?? []
        let area = spaces.filter { !$0.isExterior && $0.deletedAt == nil }.reduce(0) { $0 + $1.areaSqIn }
        let summary = PropertySummary(name: "Property", levelCount: levels.filter { !$0.isExterior }.count,
                                      interiorAreaSqIn: area, yearBuilt: p.yearBuilt)
        if summary != propertySummary {
            propertySummary = summary
            rebuildLens()
        }
    }
}
