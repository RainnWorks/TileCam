import XCTest

/// Shared base for TileCam UI tests. Centralizes launching the app with the
/// DEBUG-only `-uiTest*` launch arguments (parsed by Foundation into the
/// `NSArgumentDomain`, which `AppState.applyUITestLaunchArguments()` reads) so
/// each test boots straight into a deterministic server + stream selection.
class TileCamUITestCase: XCTestCase {
    /// The live go2rtc server the device-style tests run against.
    static let liveServerURL = "https://cameras.thenairn.com"

    /// Generous timeouts — these are real network flows over WebRTC, not local
    /// fixtures, so first-frame latency varies with the upstream cameras.
    static let connectTimeout: TimeInterval = 40
    static let unreachableTimeout: TimeInterval = 45

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Builds an XCUIApplication preset with the given server + streams.
    /// Pass `streams` as the camera names the test wants selected on launch.
    func makeApp(
        serverURL: String = TileCamUITestCase.liveServerURL,
        streams: [String],
        forceWatchUI: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestServerURL", serverURL,
            "-uiTestStreams", streams.joined(separator: ","),
        ]
        if forceWatchUI {
            app.launchArguments += ["-uiTestForceWatchUI", "YES"]
        }
        return app
    }
}
