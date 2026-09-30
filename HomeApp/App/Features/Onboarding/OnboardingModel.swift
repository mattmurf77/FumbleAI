import Foundation
import Observation
import PlanKit
import HomeCore

/// Onboarding state (HLD §4.1–4.5, spec 01 FR-PLN-01..05, spec 03 FR-EXT-01..07/15). Talks to services only through
/// the HomeCore protocols held by `AppEnvironment`.
@MainActor
@Observable
final class OnboardingModel {
    /// Screens pushed on the onboarding NavigationStack (the root is the address step).
    enum Route: Hashable {
        case chooser, scan, blocks, trace, rough, review
    }

    enum RestoreState: Equatable {
        case checking
        case ready
        /// A `property-*` zone exists in iCloud: "Restoring your home…" (FR-SYN-20).
        case restoring
    }

    /// Which path produced the current draft (review-screen copy and behavior).
    enum CreationPath: String, Hashable {
        case scan, blocks, trace, rough
    }

    // Navigation
    var routes: [Route] = []
    var restore: RestoreState = .checking

    // Address (optional, typed; no location permission — HLD §9-23)
    var addressQuery = ""
    var suggestions: [AddressSuggestion] = []
    var resolved: ResolvedAddress?
    var addressMessage: String?
    var isResolving = false

    // Draft
    var path: CreationPath?
    var draft: PlanDraft?
    /// Raw scan JSON, kept until commit so the review screen can re-import with a new story → floor mapping.
    var scanData: Data?
    var storyKinds: [Int: Level.Kind] = [:]
    /// Suggested Things the user checked (none by default, FR-PLN-38).
    var acceptedSuggestions: Set<UUID> = []
    /// Set up the "Outside" level after commit (off by default for Condo). Runs with or without an address: without
    /// one, or when the footprint lookup fails, the yard is built around the ground floor's outline.
    var seedExterior = true
    /// Rough it in: saved on the property as a sanity reference (FR-PLN-15).
    var approxSqFt: Int?

    // Commit
    var isSaving = false
    var commitError: String?

    /// Marker added by the exterior seeder when the footprint lookup failed for network reasons. Mirrors
    /// `HomeExterior.ExteriorSeeder.networkUnavailableTag`. Onboarding no longer skips the yard on it (it falls back
    /// to the ground floor's outline, see `ExteriorSetup`); kept for other callers.
    static let footprintUnavailableTag = ExteriorPlanning.footprintUnavailableTag

    // MARK: Restore check (FR-PLN-01)

    func runRestoreCheck(_ env: AppEnvironment, onFinished: @escaping () -> Void) async {
        guard restore == .checking else { return }
        switch await env.sync.restoreCheck(timeout: 8) {
        case .existingHomeFound:
            restore = .restoring
            // Wait until sync has brought the property down, then leave onboarding.
            for await p in env.plan.observeCurrentProperty() where p != nil {
                onFinished()
                return
            }
        case .noExistingHome, .unavailable:
            restore = .ready
        }
    }

    // MARK: Address

    func updateSuggestions(_ env: AppEnvironment) async {
        let q = addressQuery
        guard q.trimmingCharacters(in: .whitespaces).count >= 3 else { suggestions = []; return }
        try? await Task.sleep(nanoseconds: 250_000_000)   // debounce typing
        guard !Task.isCancelled, q == addressQuery else { return }
        suggestions = (try? await env.addresses.suggestions(for: q)) ?? []
    }

    /// Resolves the typed (or picked) address. Failure keeps going without exterior ("set up the yard by hand").
    func resolveAddress(_ env: AppEnvironment, _ text: String? = nil) async -> Bool {
        let q = (text ?? addressQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { resolved = nil; return true }
        isResolving = true
        defer { isResolving = false }
        do {
            resolved = try await env.addresses.resolve(q)
            addressQuery = resolved?.displayName ?? q
            addressMessage = nil
            suggestions = []
            return true
        } catch {
            resolved = nil
            addressMessage = "We couldn't find that address. Check it or set up the yard by hand."
            return false
        }
    }

    // MARK: Drafts

    func useDraft(_ d: PlanDraft, path: CreationPath, env: AppEnvironment) {
        draft = d
        self.path = path
        acceptedSuggestions = []
        commitError = nil
        routes.append(.review)
    }

    /// Scan: import the structure JSON with the current story mapping.
    func importScan(_ data: Data, env: AppEnvironment) throws {
        scanData = data
        let d = try env.roomPlanImporter.draft(fromCapturedStructureJSON: data, storyMap: storyKinds)
        if d.levels.flatMap(\.spaces).isEmpty {
            throw ScanImportFailure.noRooms
        }
        useDraft(d, path: .scan, env: env)
    }

    /// Review: a story was mapped to a different level kind → re-run the import, keeping user renames by position.
    func remapStory(_ story: Int, to kind: Level.Kind, env: AppEnvironment) {
        storyKinds[story] = kind
        guard let data = scanData, let old = draft,
              var d = try? env.roomPlanImporter.draft(fromCapturedStructureJSON: data, storyMap: storyKinds) else { return }
        // Carry names typed on the review screen over (same story, same order).
        for li in d.levels.indices {
            guard let prev = old.levels.first(where: { $0.storyIndex == d.levels[li].storyIndex }) else { continue }
            for si in d.levels[li].spaces.indices where si < prev.spaces.count {
                d.levels[li].spaces[si].name = prev.spaces[si].name
                d.levels[li].spaces[si].spaceType = prev.spaces[si].spaceType
            }
        }
        acceptedSuggestions = []
        draft = d
    }

    enum ScanImportFailure: Error { case noRooms }

    // MARK: Commit (FR-PLN-04/05)

    func commit(_ env: AppEnvironment, onFinished: @escaping () -> Void) async {
        guard let draft, !isSaving else { return }
        isSaving = true
        commitError = nil
        defer { isSaving = false }
        do {
            let propertyId: UUID
            if let existing = try await env.plan.currentProperty() {
                propertyId = existing.id
            } else {
                let line = resolved?.address.line ?? ""
                let p = Property(name: line.isEmpty ? "My Home" : line,
                                 address: resolved?.address, latitude: resolved?.coordinate.latitude,
                                 longitude: resolved?.coordinate.longitude, approxSqFt: approxSqFt)
                try await env.plan.saveProperty(p)
                propertyId = p.id
            }
            let levelIds = try await env.planCommitter.commit(draft, into: propertyId, acceptedSuggestions: acceptedSuggestions)
            // Open on the ground floor (sort order 0) when the draft has one.
            if let i = draft.levels.firstIndex(where: { $0.sortOrder == 0 && $0.kind != .exterior }), i < levelIds.count {
                try? await env.plan.setDefaultLevel(levelIds[i], property: propertyId)
            }
            if seedExterior {
                // Always a yard (founder bug "Exterior/yard is missing"): address → footprint when it works, else the
                // ground floor's outline with the default zones. Never blocks the canvas (FR-PLN-05).
                let ground = ExteriorPlanning.groundLevelIndex(draft.levels).flatMap { FloorMatching.outline(of: draft.levels[$0]) }
                ExteriorSetup.start(ExteriorSetup.Services(env), propertyId: propertyId, address: resolved, groundOutline: ground)
            }
            scanData = nil
            onFinished()
        } catch {
            commitError = "Couldn't save your plan. Try again."
        }
    }

    /// Exterior seeding runs after the commit and never blocks the canvas (FR-PLN-05, FR-EXT-01). A failed lookup
    /// (offline, server timeout, rate limit) no longer skips the yard: it falls back to the house block.
    static func startExteriorSeeding(env: AppEnvironment, propertyId: UUID, address: ResolvedAddress?, groundOutline: Polygon? = nil) {
        ExteriorSetup.start(ExteriorSetup.Services(env), propertyId: propertyId, address: address, groundOutline: groundOutline)
    }

    // MARK: Device capabilities

    /// FR-PLN-03: Scan only on LiDAR devices.
    static var scanSupported: Bool { ScanCapability.isSupported }
}
