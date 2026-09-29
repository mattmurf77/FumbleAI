import Foundation
import HomeCore
import GRDB

// HomeStore — GRDB persistence (LLD §3, §5.3, §8, §11–13).
// Owner fills: AppDatabase, Migrations (v1_core, v1_local, v1_search), Records/* (flat-column record wrappers
// for every HomeCore model), Repositories/* (conform to HomeCore.PlanRepository, ChoreRepository, …),
// Outbox, SearchIndexer, RollupQueries, StorageTreeQueries, LensStatsQueries, CSVExporter,
// AttachmentFileStore, PlanCommitter (HomeCore.PlanCommitting).
// Use HomeCoreTesting's in-memory implementations + SampleHome as behavioural oracles in tests.

public enum HomeStoreModule {
    public static let name = "HomeStore"
}
