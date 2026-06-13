import SwiftUI
import os

private let log = Logger(subsystem: "works.rainn.tilecam", category: "AppState")

@main
struct TileCamApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    /// Last time we ran a foreground reconnect sweep, to debounce rapid
    /// inactive↔active flicker from thrashing healthy peer connections.
    @State private var lastForegroundReconnect: Date = .distantPast
    /// Last time we ran a foreground stream-list refresh, to debounce rapid
    /// inactive↔active flicker from stacking overlapping fetches.
    @State private var lastForegroundRefresh: Date = .distantPast

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
                .onAppear {
                    PiPManager.shared.onUserClose = { [weak appState] in
                        // Closing the floating PiP window is how the user STOPS
                        // background streaming. Mark dismissed so PiP doesn't
                        // immediately re-prepare, then tear down PiP.
                        PiPManager.shared.userDismissed = true
                        PiPManager.shared.stop()

                        // If the app is backgrounded (the normal case — the PiP
                        // window is the only thing on screen), run the same clean
                        // suspend as the `.background` handler so iOS suspends us.
                        // Leave clients registered in activeClients so a later
                        // foreground revives them via reconnectStaleClients().
                        // If the app is foregrounded, do nothing else — returning
                        // to inline is handled by the `.active` path.
                        if UIApplication.shared.applicationState == .background {
                            appState?.suspendLiveMedia()
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Stop PiP rendering — no longer needed in foreground
                PiPManager.shared.pause()
                PiPManager.shared.userDismissed = false
                let streaming = !appState.serverURL.isEmpty && !appState.selectedStreams.isEmpty
                UIApplication.shared.isIdleTimerDisabled = streaming && appState.keepScreenAwake
                // Re-activate the shared audio session and rebuild the playout
                // engine if iOS tore it down while backgrounded.
                AudioSessionManager.activate()
                WebRTCFactory.shared.resumePlayout()
                // Proactively recover tile connections: ICE delegate callbacks
                // frequently don't fire after OS suspension, so PiP-mounted tiles
                // can spin forever. Reconnect any client that isn't healthy.
                reconnectStaleClients()
                // Recover the camera list if a cold-start fetch failed: nothing
                // else re-fetches on foreground, so a transient failure would
                // otherwise latch until the app is killed.
                refreshStreamsIfNeeded()
            case .inactive:
                // Prepare PiP just before backgrounding so the display layer
                // has content for canStartPictureInPictureAutomaticallyFromInline
                let clients = appState.orderedActiveClients
                if !clients.isEmpty && !PiPManager.shared.userDismissed {
                    PiPManager.shared.prepare(
                        clients: clients,
                        viewports: StreamTileView.buildViewports(appState: appState)
                    )
                }
            case .background:
                // Auto-PiP is wanted: when PiP is prepared (isActive), let it
                // float into a window and keep streams alive. Only tear down
                // when there's no PiP to float (and background audio isn't opted
                // in) — e.g. backgrounding with no active streams. The user
                // STOPS a floating PiP by closing its window, which runs the
                // same suspend via PiPManager.onUserClose (see onAppear).
                if !appState.backgroundAudioEnabled && !PiPManager.shared.isActive {
                    // Muting the track alone leaves the engine rendering and the
                    // audio session active, which keeps the background-audio
                    // assertion satisfied forever (battery drain). Tear down the
                    // live media so iOS can suspend us.
                    appState.suspendLiveMedia()
                }
            default:
                break
            }
        }
    }

    /// On foreground, reconnect any active client that isn't in a healthy ICE
    /// state. Debounced so a quick inactive↔active flicker doesn't tear down
    /// healthy peer connections.
    private func reconnectStaleClients() {
        let now = Date()
        guard now.timeIntervalSince(lastForegroundReconnect) > 2 else { return }
        lastForegroundReconnect = now

        for client in appState.orderedActiveClients {
            switch client.connectionState {
            case .connected, .completed:
                // Intentionally NOT force-reconnected even if media looks dead:
                // WebRTCClient's frameWatchdog is the safety net for "connected
                // but no frames." Reconnecting here would thrash healthy peers.
                continue
            default:
                Task { await client.connect() }
            }
        }
    }

    /// On foreground, re-fetch the camera list if we never successfully
    /// connected (or have no streams despite a configured server). Debounced so
    /// a quick inactive↔active flicker doesn't stack overlapping fetches.
    /// `refreshStreams()` already cancels any in-flight refresh on re-entry.
    private func refreshStreamsIfNeeded() {
        let needsRefresh = !appState.isConnected
            || (appState.availableStreams.isEmpty && !appState.serverURL.isEmpty)
        guard needsRefresh else { return }

        let now = Date()
        guard now.timeIntervalSince(lastForegroundRefresh) > 2 else { return }
        lastForegroundRefresh = now

        Task { await appState.refreshStreams() }
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
        didSet {
            LayoutStore.saveSelectedStreams(selectedStreams)
            syncSelectedStreamsToWatch()
        }
    }

    func syncSelectedStreamsToWatch() {
        let viewports = StreamTileView.buildViewports(appState: self)
        var entries: [[String: Any]] = []
        for stream in selectedStreams {
            let vp = viewports[stream.name] ?? (1, 0.5, 0.5)
            entries.append([
                "name": stream.name,
                "zoom": vp.0,
                "centerX": vp.1,
                "centerY": vp.2,
            ])
        }
        PhoneSessionManager.shared.updateSelectedStreams(entries)
    }

    // MARK: - Active stream clients (for PiP)

    /// Registry of active WebRTCClients, keyed by stream name.
    var activeClients: [String: WebRTCClient] = [:]
    /// Registry of current per-stream transforms, keyed by stream name.
    var activeTransforms: [String: CGAffineTransform] = [:]
    /// Registry of per-stream view sizes (in points), keyed by stream name.
    var activeContentSizes: [String: CGSize] = [:]

    /// Active clients ordered to match selectedStreams.
    var orderedActiveClients: [WebRTCClient] {
        selectedStreams.compactMap { activeClients[$0.name] }
    }

    /// Clean suspend of all live media so iOS can suspend the app: close every
    /// peer connection and stop the playout engine + deactivate the audio
    /// session. Shared by the `.background` teardown and the PiP-close path.
    ///
    /// Clients are intentionally left registered in `activeClients` (tile views
    /// stay mounted while backgrounded), so a later foreground revives them via
    /// `reconnectStaleClients()`. Idempotent: disconnecting an already-closed
    /// client and re-suspending an already-stopped engine are both no-ops.
    func suspendLiveMedia() {
        for client in orderedActiveClients {
            client.disconnect()
        }
        WebRTCFactory.shared.suspendPlayout()
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

    // MARK: - Watch streaming settings (synced to Watch)

    var watchGlanceModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "watchGlanceModeEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "watchGlanceModeEnabled")
            objectWillChange.send()
            PhoneSessionManager.shared.syncWatchSettings(buildWatchSettings())
        }
    }

    var watchDefaultStreamMode: String {
        get { UserDefaults.standard.string(forKey: "watchDefaultStreamMode") ?? "videoAndAudio" }
        set {
            UserDefaults.standard.set(newValue, forKey: "watchDefaultStreamMode")
            objectWillChange.send()
            PhoneSessionManager.shared.syncWatchSettings(buildWatchSettings())
        }
    }

    var watchStreamTimeoutMinutes: Int {
        get { UserDefaults.standard.object(forKey: "watchStreamTimeoutMinutes") as? Int ?? 60 }
        set {
            UserDefaults.standard.set(newValue, forKey: "watchStreamTimeoutMinutes")
            objectWillChange.send()
            PhoneSessionManager.shared.syncWatchSettings(buildWatchSettings())
        }
    }

    var watchGlanceDefaultCamera: String {
        get { UserDefaults.standard.string(forKey: "watchGlanceDefaultCamera") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "watchGlanceDefaultCamera")
            objectWillChange.send()
            PhoneSessionManager.shared.syncWatchSettings(buildWatchSettings())
        }
    }

    func buildWatchSettings() -> [String: Any] {
        [
            "glanceModeEnabled": watchGlanceModeEnabled,
            "defaultStreamMode": watchDefaultStreamMode,
            "streamTimeoutMinutes": watchStreamTimeoutMinutes,
            "glanceDefaultCamera": watchGlanceDefaultCamera,
        ]
    }

    // MARK: - Audio state

    /// When false (the default), the app suspends cleanly on background: peer
    /// connections close, the playout engine stops, and the audio session is
    /// deactivated. Set true to opt in to continued background audio.
    var backgroundAudioEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "backgroundAudioEnabled") as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "backgroundAudioEnabled")
            objectWillChange.send()
        }
    }

    /// When true, the device will not auto-lock while streams are being viewed.
    var keepScreenAwake: Bool {
        get { UserDefaults.standard.object(forKey: "keepScreenAwake") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "keepScreenAwake")
            objectWillChange.send()
        }
    }

    /// When true, a black overlay is drawn over the video to dim it in dark rooms.
    var videoDimmingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "videoDimmingEnabled") as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "videoDimmingEnabled")
            objectWillChange.send()
        }
    }

    /// Strength of the video dimming overlay, 0.0–1.0.
    var videoDimmingAmount: Double {
        get { UserDefaults.standard.object(forKey: "videoDimmingAmount") as? Double ?? 0.3 }
        set {
            UserDefaults.standard.set(newValue, forKey: "videoDimmingAmount")
            objectWillChange.send()
        }
    }

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

    private var watchObserver: Any?

    init() {
        self.selectedStreams = LayoutStore.loadSelectedStreams()
        updateService()
        // Sync wrist behavior to Watch on launch
        PhoneSessionManager.shared.syncWristBehavior(wristBehavior)
        // Listen for Watch-initiated changes
        watchObserver = NotificationCenter.default.addObserver(
            forName: .wristBehaviorChangedFromWatch, object: nil, queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
        NotificationCenter.default.addObserver(
            forName: .watchSettingsChangedFromWatch, object: nil, queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
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

    /// Bounded retry parameters for a cold-start fetch. Mirrors the
    /// exponential-backoff shape in `WebRTCClient.scheduleRetry`.
    private static let maxRefreshAttempts = 5
    private static let baseRefreshDelay: TimeInterval = 1
    private static let maxRefreshDelay: TimeInterval = 8

    func refreshStreams() async {
        refreshTask?.cancel()
        let task = Task {
            log.info("refreshStreams called, serverURL=\(self.serverURL)")
            guard let service = go2rtcService else {
                log.error("No go2rtcService — serverURL is empty or invalid")
                return
            }

            // Bounded retry with backoff so a transient cold-start failure
            // self-heals within a few seconds instead of latching until the
            // process is killed.
            for attempt in 1...Self.maxRefreshAttempts {
                guard !Task.isCancelled else { return }
                do {
                    log.info("Fetching streams from \(service.baseURL.absoluteString) (attempt \(attempt))")
                    let streams = try await service.fetchStreams()
                    guard !Task.isCancelled else { return }
                    availableStreams = streams
                    isConnected = true
                    log.info("Connected — found \(streams.count) streams: \(streams.map(\.name))")
                    PhoneSessionManager.shared.updateAvailableStreams(streams.map(\.name))

                    // Remove selected streams that no longer exist on the server.
                    // Skip when the server returned an empty list: a
                    // successful-but-empty/booting go2rtc response must not wipe
                    // the user's persisted selection.
                    if !streams.isEmpty {
                        let validNames = Set(streams.map(\.name))
                        let before = self.selectedStreams.count
                        self.selectedStreams.removeAll { !validNames.contains($0.name) }
                        if self.selectedStreams.count != before {
                            log.info("Removed \(before - self.selectedStreams.count) stale selected streams")
                        }
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    isConnected = false
                    availableStreams = []
                    log.error("refreshStreams failed (attempt \(attempt)): \(error)")

                    // No point sleeping after the final attempt.
                    guard attempt < Self.maxRefreshAttempts else { break }
                    let delay = min(
                        Self.baseRefreshDelay * pow(2, Double(attempt - 1)),
                        Self.maxRefreshDelay
                    )
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        // Cancelled during backoff — bail out.
                        return
                    }
                }
            }
        }
        refreshTask = task
        await task.value
    }
}
