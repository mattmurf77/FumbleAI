# Capture, Exterior & Onboarding — integration notes

Owner: capture/exterior/onboarding workstream. Packages `HomeCapture`, `HomeExterior`; feature `App/Features/Onboarding`.

## 1. Composition root (`App/AppEnvironment.swift`, `AppEnvironment.live()`)

Replace the `// INTEGRATION: HomeCapture` / `HomeExterior` comments with (and `import HomeCapture`, `import HomeExterior`
at the top of the file; `let d` → `var d`):

```swift
d.roomPlanImporter = RoomPlanImporter()
d.roughIn = RoughInGenerator()
d.blocks = BlockTemplates()
d.photoTrace = PhotoTraceCalibrator()
d.receipts = ReceiptReader(clock: d.clock)

d.addresses = AddressResolver()
d.footprints = FootprintProvider(config: config)          // Home server when AppConfig.usesServer, else Overpass
d.snapshots = SatelliteSnapshotter()                      // Caches/Snapshots/<levelId>.heic (+ .json sidecar)
d.yardSeeder = YardSeeder()
d.exteriorSeeder = ExteriorSeeder(footprints: d.footprints, seeder: d.yardSeeder)
```

All are `Sendable` structs with no required setup. `AppEnvironment.preview()` can keep the HomeCoreTesting stubs.

## 2. RootView (`App/RootView.swift`)

Show onboarding when there is no property:

```swift
if loaded && property == nil {
    OnboardingFlow(onFinished: { Task { await reload() } })   // reload = re-read env.plan.currentProperty()
}
```

- `OnboardingFlow(onFinished: @escaping () -> Void)` runs the FR-PLN-01 iCloud restore check itself
  (`env.sync.restoreCheck(timeout: 8)`); on `.existingHomeFound` it shows "Restoring your home…" and calls
  `onFinished` once `env.plan.observeCurrentProperty()` yields a property.
- On commit it creates the `Property` (address, coordinate, `approxSqFt` for Rough it in) if none exists, commits the
  draft via `env.planCommitter`, sets the default level to the ground floor, then calls `onFinished` (FR-PLN-04).
- Exterior seeding runs afterwards in a detached task (never blocks the canvas): `env.exteriorSeeder` →
  commit an `Outside` level (`source: .autoseed`) → `env.snapshots.snapshot(center:spanMeters: 90, levelId:)`.
  Skipped when there is no address, when the user turned it off on Review (default off for Condo), or when the
  lookup failed for network reasons (see §4).
- Better: observe `env.plan.observeCurrentProperty()` in RootView instead of a one-shot load, so both commit and
  iCloud restore switch screens automatically.

## 3. Things other features may use

| API | Where | Use |
|---|---|---|
| `DocumentScannerView(onFinish: ([Data]) -> Void, onCancel:)` + `.isSupported` | HomeCapture (iOS only, `#if canImport(VisionKit)`) | VNDocumentCameraViewController wrapper returning JPEG pages; feed straight into `env.receipts.read(images:)`. |
| `ReceiptReader.recognize(images:)` | HomeCapture | OCR lines only (for `attachment.ocr_text`). `ReceiptGuess.fullText` already holds the joined text. |
| `ExteriorSeeder.fallbackLevel(origin:)` | HomeExterior | Settings › "Set up outside" when geocoding fails (blank Outside with 40 × 30 ft block). |
| `RoomPlanImporter.stories(in:)` | HomeCapture | Story indices of a scan (story → floor mapping UI). |
| `BlockTemplates.blank()` | HomeCapture | "Blank" style for Add floor. |
| `PhotoTraceCalibrator.draft(image:transform:)` / `.tracedSpace(...)` | HomeCapture | Add floor → Trace a photo from the level menu. |

Canvas owners (PlanCanvas / Plan feature): exterior footer must show "© OpenStreetMap contributors" and the Apple Maps
legal attribution (FR-EXT-09); the snapshot is drawn from `SnapshotImage.fileURL` with `pixelToModel` at 60 % opacity,
30 % desaturated, rotated by `georef.rotationRad`.

## 4. HomeCore change requests (not made — HomeCore is frozen for this workstream)

1. **`DraftWarning.footprintUnavailable`** (network/rate-limit failure during exterior seeding, FR-EXT-15). Today
   `ExteriorSeeder` signals it with `.other("footprint-unavailable")` (`ExteriorSeeder.networkUnavailableTag`), and the
   onboarding model matches the same literal (`OnboardingModel.footprintUnavailableTag`). A dedicated case would
   remove the stringly-typed coupling. Someone also needs to own "retry on next launch with network, max once".
2. **`FootprintResult.candidates`** (optional): "Wrong building?" (spec 03 edge case) needs the other candidate outlines
   from the same response. `OverpassParser.parse` already returns them; the protocol result drops them.
3. **Server 404 with roads**: `/v1/footprint` returns roads even when no building qualifies; `FootprintProviding`
   returns nil there, so the 40 × 30 ft fallback block is oriented to the screen bottom instead of the road. A
   `FootprintResult` with an empty `outline` + `nearestRoadPoint` would fix it if HomeCore allowed it.
4. **`PhotoTraceCalibrating` stretched result**: the protocol returns `.failure(.possiblyStretched)` without the
   averaged transform. Onboarding recomputes the average itself on "Use anyway". A `(UnderlayTransform, TraceWarning?)`
   success value (as `PhotoTraceCalibrator.calibrateDetailed` returns) would be cleaner.
5. `HouseStyle` has no `.blank`; Blank is handled in the UI / `BlockTemplates.blank()`.

## 5. Behaviour notes / defaults taken

- Level names: "1st Floor", "2nd Floor", … (matching `Level.name` docs and `SampleHome`), "Basement", "Attic",
  split-level "Lower Level / Main Level / Upper Level"; exterior "Outside".
- Rough it in: bedroom overflow uses a capacity of one bedroom per 220 sq ft of floor (not in the LLD); 3-floor homes
  get a Family Room on the middle floor, an otherwise empty upper floor gets a Bonus Room; multi-floor halls are split
  into "Hall" + a 10 ft "Stairs" block. The garage column is added to the left of the house (not taken from the
  above-grade sq ft). Output ids are deterministic (golden tests).
- RoomPlan: small overlaps (1 sq in – 1 sq ft) are trimmed by shrinking the smaller room (no polygon difference in
  `PlanKit.Clip`); larger overlaps are flagged. Duplicate doors reported by both rooms are merged (midpoints < 6 in).
  A door touching only one room is marked `isExteriorDoor`. Floors captured in separate sessions (multi-floor
  alignment, FR-PLN-39a) are not handled by onboarding — it scans one floor; "Add floor" owns alignment.
- RoomPlan JSON: the importer decodes Apple's `CapturedStructure` JSON on iOS (bridged to `RPStructure`) and also accepts
  its own `RPStructure` JSON (`format: "home.rp.v1"`), which is what the Linux tests and fixtures use.
- Receipt dates: `NSDataDetector` is not available on Linux, so the parser matches common receipt formats explicitly
  (M/D/Y, Y-M-D, D/M/Y when day > 12, "Sep 18, 2026", "18 Sep 2026").
- Overpass `User-Agent`: `Home/1.0 (iOS; app.fumble.home)` — replace with a real contact before public release
  (OSM usage policy).
- Snapshot cache stores a JSON sidecar next to the HEIC (the LLD's `map_snapshot_cache` table is HomeStore's; the
  sidecar keeps HomeExterior independent of the database).

## 6. Verification

`swift test` on Linux: HomeCapture 24 tests, HomeExterior 18 tests, all passing. Apple-only code (RoomPlan bridge,
Vision OCR, VisionKit scanner, MapKit resolver/snapshotter) and the Onboarding SwiftUI views were written for iOS 17
but could not be compiled here; they need an Xcode build.
