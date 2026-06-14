import XCTest
import StoreKitTest

/// Phase 2 paywall gate (phone-side only — no watchOS UI testing here). Drives
/// the StoreKit test session directly to flip the watch-unlock entitlement and
/// asserts the WatchSettingsPanel reflects the LOCKED → UNLOCKED transition.
///
/// Launched with `-uiTestForceWatchUI` so the Watch settings entry point is
/// present on a simulator with no paired Watch.
final class WatchPaywallTests: TileCamUITestCase {

    /// Mirrors `StoreManager.watchUnlockProductID`. UI tests run out-of-process
    /// and can't link the app target, so the id is duplicated here.
    private static let watchUnlockProductID = "works.rainn.tilecam.watch.unlock"

    func testWatchUnlockPaywallGate() throws {
        // Fresh StoreKit test session from the same config the test plan uses.
        let session = try SKTestSession(configurationFileNamed: "TileCam")
        session.disableDialogs = true
        session.clearTransactions()

        let app = makeApp(streams: ["mia_room"], forceWatchUI: true)
        app.launch()

        // Open Watch settings.
        let watchButton = app.buttons["watch-settings-button"]
        XCTAssertTrue(
            watchButton.waitForExistence(timeout: 15),
            "Watch settings button not present (forceWatchUI hook)"
        )
        watchButton.tap()

        // LOCKED: the unlock CTA is present and the unlocked confirmation is not.
        let lockCTA = app.buttons["watch-unlock-cta"]
        XCTAssertTrue(
            lockCTA.waitForExistence(timeout: 10),
            "Expected the LOCKED 'Unlock Apple Watch' CTA before purchase"
        )
        XCTAssertFalse(
            app.otherElements["watch-unlocked-confirmation"].exists,
            "Watch unexpectedly shows unlocked before any purchase"
        )

        // Drive the purchase directly through the StoreKit test session. The app's
        // `Transaction.updates` listener (installed in StoreManager.start()) picks
        // this up and flips `isWatchUnlocked`.
        try session.buyProduct(productIdentifier: Self.watchUnlockProductID)

        // UNLOCKED: confirmation appears and the lock CTA disappears.
        let unlockedConfirmation = app.staticTexts["Unlocked"]
        let confirmationContainer = app.otherElements["watch-unlocked-confirmation"]
        let appeared = unlockedConfirmation.waitForExistence(timeout: 15)
            || confirmationContainer.waitForExistence(timeout: 1)
        XCTAssertTrue(
            appeared,
            "Watch did not flip to the unlocked/confirmation state after purchase"
        )
        XCTAssertFalse(
            lockCTA.exists,
            "LOCKED 'Unlock Apple Watch' CTA still present after purchase"
        )
    }
}
