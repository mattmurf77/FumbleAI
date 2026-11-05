import Foundation
import StoreKit

enum HomeBriefOutcome {
    case purchased(finish: () async -> Void)
    case pending, cancelled, unverified
}

/// The StoreKit boundary. Only verified transactions for this product reach delivery.
@MainActor
protocol HomeBriefCommerce {
    func loadPrice() async throws -> String?
    func purchase() async throws -> HomeBriefOutcome
    func isEntitled() async -> Bool
    func syncAccount() async throws
    func observe(onChange: @escaping @MainActor () async -> Void) async
    func recoverUnfinished(onChange: @escaping @MainActor () async -> Void) async
}

@MainActor
final class AppleHomeBriefCommerce: HomeBriefCommerce {
    // Release signing can override HOME_BUNDLE_ID. Keep the purchase scoped to the installed app.
    static let productID = Bundle.main.bundleIdentifier.map { $0 + ".homebrief" }
    private var product: Product?

    func loadPrice() async throws -> String? {
        guard let id = Self.productID else { return nil }
        product = try await Product.products(for: [id]).first { $0.id == id && $0.type == .nonConsumable }
        return product?.displayPrice
    }

    func purchase() async throws -> HomeBriefOutcome {
        guard let product else { throw StoreKitError.notAvailableInStorefront }
        switch try await product.purchase() {
        case .success(let result):
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID, transaction.productType == .nonConsumable,
                  transaction.revocationDate == nil else {
                return .unverified
            }
            return .purchased { await transaction.finish() }
        case .userCancelled: return .cancelled
        case .pending: return .pending
        @unknown default: return .unverified
        }
    }

    func isEntitled() async -> Bool {
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID, transaction.productType == .nonConsumable,
               transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func syncAccount() async throws {
        try await AppStore.sync()
    }

    func observe(onChange: @escaping @MainActor () async -> Void) async {
        for await result in StoreKit.Transaction.updates {
            await deliver(result, onChange: onChange)
        }
    }

    func recoverUnfinished(onChange: @escaping @MainActor () async -> Void) async {
        for await result in StoreKit.Transaction.unfinished {
            await deliver(result, onChange: onChange)
        }
    }

    private func deliver(_ result: VerificationResult<StoreKit.Transaction>, onChange: @MainActor () async -> Void) async {
        guard case .verified(let transaction) = result, transaction.productID == Self.productID else { return }
        await onChange()
        await transaction.finish()
    }
}
