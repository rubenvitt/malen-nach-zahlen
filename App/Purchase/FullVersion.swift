import Foundation
import Observation
import StoreKit

/// Free: the bundled motifs and `freePhotos` pictures from own photos. The full version is one
/// non-consumable purchase (no subscription, Family Sharing on) and unlocks any number of own photos.
///
/// A photo counts once „Los geht's“ created its picture; trying photos and sliders in the editor is free.
/// The count only grows, so deleting the free picture does not hand out another one.
/// Purchases stay with StoreKit on the device: no server, no account, no data for the app.
@MainActor @Observable final class FullVersion {
    static let productID = "dev.rubeen.malen.unlock"
    static let freePhotos = 1

    private(set) var isUnlocked: Bool
    private(set) var photosCreated: Int
    private(set) var product: Product?
    private(set) var isLoadingProduct = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updates: Task<Void, Never>?

    private static let unlockedKey = "fullVersion.unlocked"
    private static let photosKey = "fullVersion.photosCreated"

    /// `defaults` remembers the photo count and, until StoreKit answered, the last known entitlement.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isUnlocked = defaults.bool(forKey: Self.unlockedKey)
        photosCreated = defaults.integer(forKey: Self.photosKey)
    }

    var canCreatePhoto: Bool { isUnlocked || photosCreated < Self.freePhotos }

    func photoCreated() {
        photosCreated += 1
        defaults.set(photosCreated, forKey: Self.photosKey)
    }

    /// Reads the entitlement once and then follows purchases made elsewhere: another device,
    /// Ask to Buy approved later, a refund.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        setUnlocked(owned)
    }

    func loadProduct() async {
        guard product == nil, !isLoadingProduct else { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        product = try? await Product.products(for: [Self.productID]).first
    }

    enum Outcome { case unlocked, pending, cancelled, failed }

    /// Takes the result of SwiftUI's `purchase` action.
    func complete(_ result: Product.PurchaseResult) async -> Outcome {
        switch result {
        case .success(.verified(let transaction)):
            await transaction.finish()
            setUnlocked(true)
            return .unlocked
        case .success(.unverified):
            return .failed
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .failed
        }
    }

    /// „Käufe wiederherstellen“: asks the App Store for this Apple Account's purchases.
    func restore() async -> Bool {
        try? await AppStore.sync()
        await refresh()
        return isUnlocked
    }

    private func setUnlocked(_ value: Bool) {
        if isUnlocked != value { isUnlocked = value }
        defaults.set(value, forKey: Self.unlockedKey)
    }
}
