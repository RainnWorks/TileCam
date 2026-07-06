import Foundation
import StoreKit
import os

private let log = Logger(subsystem: "works.rainn.tilecam", category: "Store")

/// Manages the one-time Apple Watch unlock IAP (StoreKit 2).
///
/// Sold from iPhone/iPad only; the phone/iPad app itself is free. The watch is
/// hard-locked behind a single non-consumable purchase. The phone is the source
/// of truth: on every entitlement change we persist the flag and push it to the
/// Watch via `PhoneSessionManager`, which tears down any in-flight watch stream
/// on revocation.
///
/// Verification is client-side only: `Transaction.currentEntitlements` for the
/// current state plus a `Transaction.updates` listener installed at launch so
/// revocations that happen while the app is closed are caught on next launch.
@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    /// Product identifier for the non-consumable watch unlock. Family Shareable.
    /// Must match App Store Connect and `TileCam.storekit`.
    static let watchUnlockProductID = "works.rainn.tilecam.watch.unlock"

    /// UserDefaults key mirroring the unlock entitlement (read on cold launch).
    private static let unlockedKey = "watchUnlocked"

    /// True when the watch unlock is owned. Seeded from UserDefaults so the UI
    /// renders the right state before StoreKit finishes its async refresh.
    @Published private(set) var isWatchUnlocked: Bool

    /// The unlock product, loaded for price display. Nil until `loadProduct()`.
    @Published private(set) var product: Product?

    /// True while a purchase is in flight, so the buy button can disable itself.
    @Published private(set) var isPurchasing = false

    /// Long-lived task observing `Transaction.updates` for the app's lifetime.
    private var updatesListener: Task<Void, Never>?

    private init() {
        self.isWatchUnlocked = UserDefaults.standard.bool(forKey: Self.unlockedKey)
    }

    /// Installs the transaction-updates listener and runs an initial entitlement
    /// refresh + product load. Call once at launch, BEFORE the UI appears, so a
    /// revocation that happened while the app was closed is caught.
    func start() {
        guard updatesListener == nil else { return }
        #if DEBUG
        // Test-only: force the Watch unlock so marketing / UI captures can show the
        // live Watch experience without a StoreKit purchase. Gated to DEBUG and a
        // launch arg (`-uiTestForceWatchUnlock YES`), matching the other -uiTest
        // hooks; no effect in normal use. Skips the entitlement refresh so it
        // isn't immediately reset to locked.
        if UserDefaults.standard.bool(forKey: "uiTestForceWatchUnlock") {
            isWatchUnlocked = true
            UserDefaults.standard.set(true, forKey: Self.unlockedKey)
            PhoneSessionManager.shared.setWatchEntitlement(true)
            updatesListener = Task {}   // mark started; bypass the real refresh
            return
        }
        #endif
        Task {
            // Establish authoritative state from currentEntitlements FIRST, then
            // install the lifetime updates listener — otherwise the two race and
            // could push a transient wrong entitlement to the Watch.
            await refreshEntitlements()
            if updatesListener == nil {
                updatesListener = Task.detached { [weak self] in
                    for await result in Transaction.updates {
                        await self?.handle(transactionResult: result)
                    }
                }
            }
            await loadProduct()
        }
    }

    /// Loads the unlock product from the App Store for price display.
    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.watchUnlockProductID])
            product = products.first
            if product == nil {
                log.error("Watch unlock product not found for id \(Self.watchUnlockProductID)")
            }
        } catch {
            log.error("Failed to load watch unlock product: \(error)")
        }
    }

    /// Initiates the purchase flow. Verifies the resulting transaction and
    /// updates entitlement state on success.
    func purchase() async {
        guard let product else {
            log.error("Purchase requested but product is not loaded")
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if let transaction = verified(verification) {
                    await setUnlocked(true)
                    await transaction.finish()
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            log.error("Purchase failed: \(error)")
        }
    }

    /// Restores purchases by syncing with the App Store, then re-checks
    /// entitlements. Mandatory for App Store review.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            log.error("AppStore.sync failed: \(error)")
        }
        await refreshEntitlements()
    }

    /// Iterates current entitlements, verifies each, and sets the unlock state.
    /// A revoked transaction (`revocationDate != nil`) does not count.
    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = verified(result) else { continue }
            if transaction.productID == Self.watchUnlockProductID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        await setUnlocked(unlocked)
    }

    // MARK: - Private

    /// Handles a transaction delivered by the `Transaction.updates` stream
    /// (purchases on other devices, Family Sharing changes, refunds/revocations).
    private func handle(transactionResult result: VerificationResult<Transaction>) async {
        guard let transaction = verified(result) else { return }
        if transaction.productID == Self.watchUnlockProductID {
            await setUnlocked(transaction.revocationDate == nil)
        }
        await transaction.finish()
    }

    /// Unwraps a StoreKit verification result, returning nil if verification fails.
    private nonisolated func verified<T>(_ result: VerificationResult<T>) -> T? {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified(_, let error):
            log.error("Transaction failed verification: \(error)")
            return nil
        }
    }

    /// Single chokepoint for entitlement state changes: persists the flag and
    /// pushes it to the Watch (which tears down any in-flight stream on lock).
    private func setUnlocked(_ unlocked: Bool) async {
        #if DEBUG
        // Test-only: with the force-unlock flag set, never let the (empty) StoreKit
        // entitlement refresh lock us back down — keeps the Watch unlocked for captures.
        if UserDefaults.standard.bool(forKey: "uiTestForceWatchUnlock") && !unlocked { return }
        #endif
        // Idempotent: only act on an actual state change. Otherwise every benign
        // refresh (launch, a locked user tapping Restore, foreground refresh)
        // would re-run setWatchEntitlement(false) and tear down a stream.
        guard isWatchUnlocked != unlocked else { return }
        UserDefaults.standard.set(unlocked, forKey: Self.unlockedKey)
        isWatchUnlocked = unlocked
        PhoneSessionManager.shared.setWatchEntitlement(unlocked)
    }
}
