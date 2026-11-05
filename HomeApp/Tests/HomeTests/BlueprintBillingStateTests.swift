import Foundation
import Testing
@testable import Home

@MainActor
private final class TestCommerce: HomeBriefCommerce {
    var price: String?
    var entitled = false
    var result: HomeBriefOutcome = .cancelled
    var shouldFailPayment = false
    var shouldFailRestore = false
    var suspendPayment = false
    var suspendEntitlements = false
    var recovered = false
    var entitlementReads: [CheckedContinuation<Bool, Never>] = []
    var pendingPayment: CheckedContinuation<Void, Never>?
    var purchases = 0
    var restored = 0
    var onChange: (@MainActor () async -> Void)?

    func loadPrice() async throws -> String? { price }

    func purchase() async throws -> HomeBriefOutcome {
        purchases += 1
        if suspendPayment {
            await withCheckedContinuation { pendingPayment = $0 }
        }
        if shouldFailPayment { throw CocoaError(.fileReadUnknown) }
        return result
    }

    func isEntitled() async -> Bool {
        guard suspendEntitlements else { return entitled }
        return await withCheckedContinuation { entitlementReads.append($0) }
    }

    func nextEntitlementRead() async throws -> CheckedContinuation<Bool, Never> {
        for _ in 0..<100 where entitlementReads.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let read = try #require(entitlementReads.first)
        entitlementReads.removeFirst()
        return read
    }

    func syncAccount() async throws {
        restored += 1
        if shouldFailRestore { throw CocoaError(.fileReadUnknown) }
    }

    func observe(onChange: @escaping @MainActor () async -> Void) async { self.onChange = onChange }
    func recoverUnfinished(onChange: @escaping @MainActor () async -> Void) async { recovered = true }
}

@MainActor
struct BlueprintBillingStateTests {
    @Test func overlappingRefreshesApplyVerifiedAccessBeforeReturning() async throws {
        let commerce = TestCommerce()
        let store = BlueprintBilling(commerce: commerce)
        for _ in 0..<100 where !commerce.recovered { try await Task.sleep(for: .milliseconds(5)) }
        try #require(commerce.recovered)
        commerce.suspendEntitlements = true

        let first = Task { await store.refreshEntitlements(); return store.unlocked }
        let firstRead = try await commerce.nextEntitlementRead()
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await store.refreshEntitlements()
        }
        for _ in 0..<100 where !secondStarted { try await Task.sleep(for: .milliseconds(5)) }
        try #require(secondStarted)

        firstRead.resume(returning: true)
        let hadAccess = await first.value
        #expect(hadAccess)
        let secondRead = try await commerce.nextEntitlementRead()
        secondRead.resume(returning: false)
        await second.value
        #expect(!store.unlocked)
    }

    @Test func demoPurchasesAndRestoreNeverContactApple() async {
        let commerce = TestCommerce()
        commerce.price = "$14.99"
        commerce.entitled = true
        let store = BlueprintBilling(commerce: commerce, isDemo: true)
        await store.loadProduct()
        await store.refreshEntitlements()
        await store.purchase()
        await store.restore()
        #expect(store.price == nil)
        #expect(!store.unlocked)
        #expect(commerce.purchases == 0)
        #expect(commerce.restored == 0)
        #expect(commerce.onChange == nil)
    }

    @Test func unavailablePriceBlocksPurchaseAndSupportsRetry() async {
        let commerce = TestCommerce()
        let store = BlueprintBilling(commerce: commerce)
        await store.loadProduct()
        await store.purchase()
        #expect(commerce.purchases == 0)
        #expect(!store.unlocked)
        commerce.price = "€12,99"
        await store.loadProduct()
        #expect(store.price == "€12,99")
        commerce.price = "CA$19.99"
        await store.loadProduct(refresh: true)
        #expect(store.price == "CA$19.99")
        commerce.price = nil
        await store.loadProduct(refresh: true)
        await store.purchase()
        #expect(commerce.purchases == 0)
    }

    @Test func cancelledUnverifiedFailedAndPendingPaymentsKeepHomeBriefLocked() async {
        let commerce = TestCommerce()
        commerce.price = "$14.99"
        let store = BlueprintBilling(commerce: commerce)
        await store.loadProduct()
        await store.purchase()
        #expect(!store.unlocked)
        #expect(store.message == nil)

        commerce.result = .unverified
        await store.purchase()
        #expect(!store.unlocked)
        #expect(store.message?.contains("verify") == true)

        commerce.shouldFailPayment = true
        await store.purchase()
        #expect(!store.unlocked)
        #expect(!store.busy)
        #expect(store.message?.contains("could not be completed") == true)

        commerce.shouldFailPayment = false
        commerce.result = .pending
        await store.purchase()
        #expect(!store.unlocked)
        #expect(store.message?.contains("awaiting approval") == true)
    }

    @Test func duplicateTapsDoNotStartASecondPurchaseOrRestore() async throws {
        let commerce = TestCommerce()
        commerce.price = "$14.99"
        commerce.suspendPayment = true
        let store = BlueprintBilling(commerce: commerce)
        await store.loadProduct()
        let first = Task { await store.purchase() }
        for _ in 0..<100 where commerce.pendingPayment == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let payment = try #require(commerce.pendingPayment)
        #expect(store.busy)
        await store.purchase()
        await store.restore()
        #expect(commerce.purchases == 1)
        #expect(commerce.restored == 0)
        payment.resume()
        await first.value
        #expect(!store.busy)
    }

    @Test func verifiedPurchaseDeliversBeforeTheEntitlementSnapshotRefreshes() async {
        let commerce = TestCommerce()
        commerce.price = "$14.99"
        var finished = false
        commerce.result = .purchased { finished = true }
        let store = BlueprintBilling(commerce: commerce)
        await store.loadProduct()
        await store.purchase()
        #expect(store.unlocked)
        #expect(finished)
        // The App Store client already verified this particular purchase.
        #expect(!commerce.entitled)
        await store.purchase()
        #expect(commerce.purchases == 1)
    }

    @Test func restoreHandlesMissingEntitlementAndNetworkFailure() async {
        let commerce = TestCommerce()
        let store = BlueprintBilling(commerce: commerce)
        await store.restore()
        #expect(!store.unlocked)
        #expect(store.message?.contains("No Home Brief purchase") == true)
        commerce.entitled = true
        await store.restore()
        #expect(store.unlocked)
        commerce.shouldFailRestore = true
        await store.restore()
        #expect(store.unlocked)
        #expect(!store.busy)
        #expect(store.message?.contains("could not restore") == true)
    }

    @Test func updatesDeliverPendingApprovalsAndRevokeRefundedPurchases() async throws {
        let commerce = TestCommerce()
        let store = BlueprintBilling(commerce: commerce)
        for _ in 0..<100 where commerce.onChange == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let update = try #require(commerce.onChange)
        #expect(!store.unlocked)
        commerce.entitled = true
        await update()
        #expect(store.unlocked)
        commerce.entitled = false
        await update()
        #expect(!store.unlocked)
    }
}
