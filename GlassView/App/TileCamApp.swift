import SwiftUI
import os

private let log = Logger(subsystem: "works.rainn.tilecam", category: "AppState")

@main
struct TileCamApp: App {
    @StateObject private var appState = AppState()

    init() {
        AudioSessionManager.configure()
        Task.detached(priority: .utility) {
            WebRTCClient.warmUp()
        }
        // Activate WatchConnectivity early
        _ = PhoneSessionManager.shared
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
    @Published var availableStreams: [Stream] = []
    @Published var isConnected = false
    @Published private(set) var go2rtcService: Go2RTCService?

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "serverURL") ?? "" }
        set {
            let old = serverURL
            UserDefaults.standard.set(newValue, forKey: "serverURL")
            objectWillChange.send()
            if newValue != old {
                updateService()
            }
        }
    }

    @Published var selectedStreams: [Stream] {
        didSet { LayoutStore.saveSelectedStreams(selectedStreams) }
    }

    // MARK: - Watch wrist-down behavior

    /// Controls what happens when the user lowers their wrist while streaming to the Watch.
    /// "eco" = stop everything, "audioOnly" = keep audio playing, "alwaysOn" = keep both streams.
    var wristBehavior: String {
        get { UserDefaults.standard.string(forKey: "wristBehavior") ?? "eco" }
        set {
            UserDefaults.standard.set(newValue, forKey: "wristBehavior")
            objectWillChange.send()
            PhoneSessionManager.shared.syncWristBehavior(newValue)
        }
    }

    // MARK: - Audio state

    var isGlobalAudioEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "isGlobalAudioEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "isGlobalAudioEnabled")
            objectWillChange.send()
        }
    }

    var mutedStreamNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mutedStreamNames") ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "mutedStreamNames")
            objectWillChange.send()
        }
    }

    func isStreamAudioEnabled(_ streamName: String) -> Bool {
        isGlobalAudioEnabled && !mutedStreamNames.contains(streamName)
    }

    func toggleStreamMute(_ streamName: String) {
        if mutedStreamNames.contains(streamName) {
            mutedStreamNames.remove(streamName)
        } else {
            mutedStreamNames.insert(streamName)
        }
    }

    init() {
        self.selectedStreams = LayoutStore.loadSelectedStreams()
        updateService()
        // Sync wrist behavior to Watch on launch
        PhoneSessionManager.shared.syncWristBehavior(wristBehavior)
    }

    private func updateService() {
        guard !serverURL.isEmpty, let url = URL(string: serverURL) else {
            go2rtcService = nil
            PhoneSessionManager.shared.updateService(nil)
            return
        }
        let service = Go2RTCService(baseURL: url)
        go2rtcService = service
        PhoneSessionManager.shared.updateService(service)
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
                PhoneSessionManager.shared.updateAvailableStreams(streams.map(\.name))

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
