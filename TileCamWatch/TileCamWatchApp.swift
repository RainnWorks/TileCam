import SwiftUI

@main
struct TileCamWatchApp: App {
    @StateObject private var sessionManager = WatchSessionManager.shared

    var body: some Scene {
        WindowGroup {
            CameraListView()
                .environmentObject(sessionManager)
        }
    }
}
