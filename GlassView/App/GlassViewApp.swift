import SwiftUI
import os

private let log = Logger(subsystem: "com.glassview.app", category: "AppState")

@main
struct GlassViewApp: App {
    @StateObject private var appState = AppState()

    init() {
        AudioSessionManager.configure()
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

    @Published var selectedStreams: [Stream] {
        didSet { LayoutStore.saveSelectedStreams(selectedStreams) }
    }

    var go2rtcService: Go2RTCService? {
        guard let url = URL(string: serverURL), !serverURL.isEmpty else { return nil }
        return Go2RTCService(baseURL: url)
    }

    init() {
        self.selectedStreams = LayoutStore.loadSelectedStreams()
    }

    private var refreshTask: Task<Void, Never>?

    func refreshStreams() async {
        refreshTask?.cancel()
        let task = Task {
            log.info("refreshStreams called, serverURL=\(self.serverURL)")
            guard let service = go2rtcService else {
                log.error("No go2rtcService — serverURL is empty or invalid")
                return
            }
            do {
                guard !Task.isCancelled else { return }
                log.info("Fetching streams from \(service.baseURL.absoluteString)")
                let streams = try await service.fetchStreams()
                guard !Task.isCancelled else { return }
                availableStreams = streams
                isConnected = true
                log.info("Connected — found \(streams.count) streams: \(streams.map(\.name))")

                // Remove selected streams that no longer exist on the server
                let validNames = Set(streams.map(\.name))
                let before = self.selectedStreams.count
                self.selectedStreams.removeAll { !validNames.contains($0.name) }
                if self.selectedStreams.count != before {
                    log.info("Removed \(before - self.selectedStreams.count) stale selected streams")
                }
            } catch {
                guard !Task.isCancelled else { return }
                isConnected = false
                availableStreams = []
                log.error("refreshStreams failed: \(error)")
            }
        }
        refreshTask = task
        await task.value
    }
}
