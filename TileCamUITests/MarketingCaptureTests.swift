import XCTest

/// Marketing capture driver (NOT a pass/fail test). Drives the exact demo the
/// website wants on the iPad in landscape:
///   1. Start with an empty grid, the bottom stream tokens visible.
///   2. Tap each token in turn so tiles pop into the grid one by one.
///   3. Hide the chrome, then double-tap-zoom into each tile at a deliberate
///      focal point (the animal), hold, and reset — proving you can pull detail
///      out of any feed and that the grid uses the whole screen.
///
/// Run on the booted iPad sim against the local go2rtc while `simctl io
/// recordVideo` captures the screen; the resulting mp4 is trimmed to a GIF.
/// Gated behind the `-uiTestCaptureDemo` arg so it never runs in CI suites.
final class MarketingCaptureTests: TileCamUITestCase {

    /// (stream name, focal point as a normalized offset within the tile).
    /// Focal points are chosen per camera so each zoom lands on the subject.
    private let cameras: [(name: String, fx: CGFloat, fy: CGFloat)] = [
        ("living_room", 0.42, 0.55),  // cat tree / floor toys
        ("garden",      0.46, 0.40),  // the bird feeder
        ("puppies",     0.52, 0.50),  // sleeping puppies
        ("kennel",      0.45, 0.55),  // dog in the yard
        ("barn",        0.42, 0.55),  // the horse
        ("waterhole",   0.52, 0.46),  // animals on the horizon
    ]

    func testCaptureDemo() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestServerURL", "http://192.168.99.86:1984",
            // Launch with NO streams selected so the grid starts empty and we
            // load tiles by tapping the bottom tokens on camera.
            "-uiTestStreams", "",
        ]
        app.launch()

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)

        // --- Phase 1: tap the bottom tokens to load tiles one by one ---
        for cam in cameras {
            let label = cam.name.replacingOccurrences(of: "_", with: " ")
            let token = app.buttons[label]
            if token.waitForExistence(timeout: 8) {
                token.tap()
                Thread.sleep(forTimeInterval: 0.6)  // quick, deliberate cadence
            }
        }

        // Wait for the feeds to actually be playing before we zoom. The first
        // is the slow one (cold WebRTC handshake); the rest are usually warm.
        _ = app.otherElements["tile-\(cameras[0].name)-playing"].waitForExistence(timeout: 25)
        for cam in cameras.dropFirst() {
            _ = app.otherElements["tile-\(cam.name)-playing"].waitForExistence(timeout: 8)
        }
        Thread.sleep(forTimeInterval: 1.5)

        // Hide the chrome (single tap) so the zoom reads clean and full-bleed.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)

        // --- Phase 2: pinch-zoom into each tile, hold on the subject, zoom back ---
        // Pinch drives the tile's MagnifyGesture directly (a synthetic double-tap
        // gets stolen by the single-tap toggle), so this reliably zooms the feed.
        // The app clamps scale >= 1 on gesture end, so a hard pinch-out resets it.
        for cam in cameras {
            let tile = app.otherElements["tile-\(cam.name)-playing"]
            guard tile.exists else { continue }

            tile.pinch(withScale: 3.0, velocity: 3.0)    // push in close on the subject
            Thread.sleep(forTimeInterval: 1.3)
            tile.pinch(withScale: 0.25, velocity: -3.0)  // zoom back out (clamps to 1x)
            Thread.sleep(forTimeInterval: 0.5)
        }

        Thread.sleep(forTimeInterval: 1.2)
    }
}
