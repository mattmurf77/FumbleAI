import Foundation
import HomeCore
import HomeStore
#if canImport(CloudKit)
import CloudKit
#endif

// HomeSync — CKSyncEngine adapter (LLD §5). Owner fills: SyncCoordinator (actor, CKSyncEngineDelegate,
// conforms to HomeCore.SyncServicing), SyncEngineProtocol, RecordMapper + Mappers/*, MergePolicy,
// OrphanParking, AccountHandling. Container id: AppConfig.main.cloudKitContainerIdentifier
// ("iCloud.$(HOME_BUNDLE_ID)"); zone per property: Property.zoneName(for:).

public enum HomeSyncModule {
    public static let name = "HomeSync"
}
