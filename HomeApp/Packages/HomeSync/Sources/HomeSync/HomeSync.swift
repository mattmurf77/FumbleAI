import Foundation
import HomeCore
import HomeStore

// HomeSync — CKSyncEngine adapter (LLD §5).
// - SyncCoordinator (actor, SyncServicing): orchestration, status, account changes. Entry point:
//   `SyncCoordinator.live(store:containerIdentifier:)` with `AppConfig.cloudKitContainerIdentifier`.
// - SyncProcessor: engine-agnostic apply/merge/sent handling over HomeStore's `SyncStore`.
// - RecordMapper (+ registry): schema-driven row ↔ record mapping, one per record type.
// - MergePolicy: §5.4 column overlay + exceptions.
// - CloudKitSyncEngine: the CKSyncEngine driver, only where CloudKit exists (`#if canImport(CloudKit)`).

public enum HomeSyncModule {
    public static let name = "HomeSync"
}
