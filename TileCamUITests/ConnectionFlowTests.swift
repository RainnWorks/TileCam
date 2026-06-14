import XCTest

/// Phase 2 connection flows against the live go2rtc server. These exercise the
/// real WebRTC connect path end to end, so timeouts are generous and assertions
/// are written to be order-independent (tiles negotiate concurrently).
final class ConnectionFlowTests: TileCamUITestCase {

    /// Both healthy cameras reach a video-playing state and neither is stuck on
    /// the connecting spinner.
    func testConnectsAndShowsVideo() {
        let app = makeApp(streams: ["mia_room", "kitchen"])
        app.launch()

        let mia = app.otherElements["tile-mia_room-playing"]
        let kitchen = app.otherElements["tile-kitchen-playing"]

        XCTAssertTrue(
            mia.waitForExistence(timeout: Self.connectTimeout),
            "mia_room never reached the video-playing state"
        )
        XCTAssertTrue(
            kitchen.waitForExistence(timeout: Self.connectTimeout),
            "kitchen never reached the video-playing state"
        )

        // No tile should still be showing a connecting spinner once both play.
        XCTAssertFalse(
            app.otherElements["tile-mia_room-connecting"].exists,
            "mia_room is stuck on the connecting spinner"
        )
        XCTAssertFalse(
            app.otherElements["tile-kitchen-connecting"].exists,
            "kitchen is stuck on the connecting spinner"
        )
    }

    /// A healthy camera plays while a genuinely-dead camera surfaces the
    /// "Camera unreachable" state. `front_garden` returns HTTP 500 upstream.
    func testUnreachableCameraShowsState() {
        let app = makeApp(streams: ["mia_room", "front_garden"])
        app.launch()

        let mia = app.otherElements["tile-mia_room-playing"]
        // The unreachable overlay is a Button; match it anywhere in the tree.
        let unreachable = app.descendants(matching: .any)["tile-front_garden-unreachable"]

        XCTAssertTrue(
            mia.waitForExistence(timeout: Self.connectTimeout),
            "mia_room never reached the video-playing state"
        )
        XCTAssertTrue(
            unreachable.waitForExistence(timeout: Self.unreachableTimeout),
            "front_garden never surfaced the 'Camera unreachable' state"
        )
    }

    /// Backgrounding and reactivating should recover the tiles to video,
    /// validating the foreground reconnect/refresh path in TileCamApp.
    func testBackgroundForegroundRecovery() {
        let app = makeApp(streams: ["mia_room", "kitchen"])
        app.launch()

        let mia = app.otherElements["tile-mia_room-playing"]
        let kitchen = app.otherElements["tile-kitchen-playing"]

        XCTAssertTrue(
            mia.waitForExistence(timeout: Self.connectTimeout),
            "mia_room never reached the video-playing state before backgrounding"
        )
        XCTAssertTrue(
            kitchen.waitForExistence(timeout: Self.connectTimeout),
            "kitchen never reached the video-playing state before backgrounding"
        )

        // Send to background and hold long enough that the scene actually reaches
        // `.background` and runs `suspendLiveMedia()` (a too-fast reactivate skips
        // the suspend, so the recovery path under test never exercises).
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 10)
        Thread.sleep(forTimeInterval: 3)

        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "App did not return to foreground"
        )

        // The video-playing identifiers drop while peers re-handshake; assert they
        // come back within the connect timeout (the foreground reconnect path).
        XCTAssertTrue(
            mia.waitForExistence(timeout: Self.connectTimeout),
            "mia_room did not recover to video after foregrounding"
        )
        XCTAssertTrue(
            kitchen.waitForExistence(timeout: Self.connectTimeout),
            "kitchen did not recover to video after foregrounding"
        )
    }
}
