import StoreKitTest
import XCTest
@testable import Home

final class HomeBriefBillingTests: XCTestCase {
    @MainActor
    private func makeSession() throws -> SKTestSession {
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "HomeBrief", withExtension: "storekit"))
        XCTAssertEqual(BlueprintBilling.productID, "app.fumble.home.homebrief", "Simulator StoreKit tests use the default HOME_BUNDLE_ID.")
        let session = try SKTestSession(contentsOf: config)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    @MainActor
    private func waitFor(_ expected: Bool, in store: BlueprintBilling, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if store.unlocked == expected { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(store.unlocked, expected, file: file, line: line)
    }

    @MainActor
    func testPurchaseFreshInstanceEntitlementAndRefund() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = BlueprintBilling()
        await store.refreshEntitlements()
        XCTAssertFalse(store.unlocked)
        await store.loadProduct()
        _ = try XCTUnwrap(store.price, "The local StoreKit catalog did not load.")
        await store.purchase()
        try await waitFor(true, in: store)

        let restored = BlueprintBilling()
        await restored.refreshEntitlements()
        XCTAssertTrue(restored.unlocked)
        // Fresh-instance entitlement restoration exercises StoreKit without opening an Apple Account login.
        // The user-triggered AppStore.sync path has a separate injected commerce test.
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == BlueprintBilling.productID })
        try session.refundTransaction(identifier: transaction.identifier)
        try await waitFor(false, in: restored)
    }

    @MainActor
    func testPendingPurchaseUnlocksOnlyAfterApproval() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let store = BlueprintBilling()
        await store.loadProduct()
        _ = try XCTUnwrap(store.price, "The local StoreKit catalog did not load.")
        await store.purchase()
        XCTAssertFalse(store.unlocked)
        XCTAssertTrue(store.message?.contains("awaiting approval") == true)
        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await waitFor(true, in: store)
    }

    @MainActor
    func testFailedPaymentDoesNotGrantAccess() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = BlueprintBilling()
        await store.loadProduct()
        _ = try XCTUnwrap(store.price, "The local StoreKit catalog did not load.")
        session.failTransactionsEnabled = true
        await store.purchase()
        XCTAssertFalse(store.unlocked)
        XCTAssertNotNil(store.message)
    }
}
