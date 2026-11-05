import Combine
import Foundation

@MainActor
final class BlueprintBilling: ObservableObject {
    static let productID = AppleHomeBriefCommerce.productID

    @Published private(set) var unlocked = false
    @Published private(set) var price: String?
    @Published private(set) var loadingProduct = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    let isDemo: Bool
    private let commerce: HomeBriefCommerce
    private var observer: Task<Void, Never>?
    private var entitlementRead: Task<Void, Never>?
    private var purchaseRevision = 0

    convenience init(isDemo: Bool = false) { self.init(commerce: AppleHomeBriefCommerce(), isDemo: isDemo) }

    init(commerce: HomeBriefCommerce, isDemo: Bool = false) {
        self.commerce = commerce
        self.isDemo = isDemo
        guard !isDemo else { return }
        observer = Task { [weak self, commerce] in
            await commerce.observe { [weak self] in await self?.refreshEntitlements() }
        }
        Task { [weak self, commerce] in
            await self?.refreshEntitlements()
            await commerce.recoverUnfinished { [weak self] in await self?.refreshEntitlements() }
        }
    }

    deinit { observer?.cancel() }

    func loadProduct(refresh: Bool = false) async {
        guard !isDemo, !busy, !loadingProduct, refresh || price == nil else { return }
        loadingProduct = true
        defer { loadingProduct = false }
        price = try? await commerce.loadPrice()
    }

    func refreshEntitlements() async {
        guard !isDemo else { return }
        // Startup, scene activation, restore and transaction updates can all request a
        // read. Each caller must return after applying a verified snapshot.
        while let pending = entitlementRead { await pending.value }
        let revision = purchaseRevision
        let read = Task {
            let entitled = await commerce.isEntitled()
            if revision == purchaseRevision {
                if unlocked != entitled { message = nil }
                unlocked = entitled
            }
            entitlementRead = nil
        }
        entitlementRead = read
        await read.value
    }

    func purchase() async {
        guard !isDemo, !busy, !loadingProduct, !unlocked, price != nil else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            switch try await commerce.purchase() {
            case .purchased(let finish):
                // A newly verified purchase can arrive before the entitlement sequence refreshes.
                // Deliver immediately and invalidate an older entitlement read already in flight.
                purchaseRevision += 1
                unlocked = true
                await finish()
                if unlocked { message = "Home Brief is ready to use." }
            case .unverified:
                message = "Apple could not verify this purchase. Try Restore Purchase."
            case .pending:
                message = "Your purchase is awaiting approval. Home Brief will unlock when Apple confirms it."
            case .cancelled:
                break
            }
        } catch {
            message = "The purchase could not be completed. Check your App Store connection and try again."
        }
    }

    func restore() async {
        guard !isDemo, !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await commerce.syncAccount()
            await refreshEntitlements()
            message = unlocked ? "Your Home Brief purchase has been restored." : "No Home Brief purchase was found for this Apple Account."
        } catch {
            message = "The App Store could not restore purchases. Check your connection and try again."
        }
    }
}
