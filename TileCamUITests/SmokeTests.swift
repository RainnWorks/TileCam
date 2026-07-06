import XCTest

/// Phase 1 smoke test: the app launches and reaches a usable state. Verifies the
/// test harness wiring (target, host app, test plan, launch-argument hook) end to
/// end before the heavier network-bound flow tests run.
final class SmokeTests: TileCamUITestCase {
    func testAppLaunches() {
        let app = makeApp(streams: ["mia_room"])
        app.launch()

        // The app reaches its running, foreground state. `state` settling to
        // `.runningForeground` is the minimal "it didn't crash on launch" signal.
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "App did not reach runningForeground after launch"
        )
    }
}
