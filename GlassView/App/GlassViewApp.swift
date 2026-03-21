import SwiftUI
import os

private let log = Logger(subsystem: "com.glassview.app", category: "AppState")

@main
struct GlassViewApp: App {
    @StateObject private var appState = AppState()

    init() {
        AudioSessionManager.configure()
        // Warm up WebRTC factory on a background thread so the first
        // stream tile doesn't stall the UI
        Task.detached(priority: .utility) {
            WebRTCClient.warmUp()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @AppStorage("serverURL") var serverURL: String = ""
    @Published var availableStreams: [Stream] = []
    @Published var isConnected = false
    @Published var globalContentMode: VideoContentMode

    @Published var selectedStreams: [Stream] {
        didSet { LayoutStore.saveSelectedStreams(selectedStreams) }
    }

    var go2rtcService: Go2RTCService? {
        guard let url = URL(string: serverURL), !serverURL.isEmpty else { return nil }
        return Go2RTCService(baseURL: url)
    }

    init() {
        self.selectedStreams = LayoutStore.loadSelectedStreams()
        self.globalContentMode = LayoutStore.loadGlobalContentMode()
    }

    func refreshStreams() async {
        log.info("refreshStreams called, serverURL=\(self.serverURL)")
        guard let service = go2rtcService else {
            log.error("No go2rtcService — serverURL is empty or invalid")
            return
        }
        do {
            log.info("Fetching streams from \(service.baseURL.absoluteString)")
            availableStreams = try await service.fetchStreams()
            isConnected = true
            log.info("Connected — found \(self.availableStreams.count) streams: \(self.availableStreams.map(\.name))")
        } catch {
            isConnected = false
            availableStreams = []
            log.error("refreshStreams failed: \(error)")
        }
    }

    func setGlobalContentMode(_ mode: VideoContentMode) {
        globalContentMode = mode
        LayoutStore.saveGlobalContentMode(mode)
    }
}
