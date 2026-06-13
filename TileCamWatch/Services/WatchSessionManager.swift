import Foundation
import WatchConnectivity
import UIKit
import os

private let log = Logger(subsystem: "works.rainn.tilecam.watch", category: "Session")

/// A stream currently visible on the iPhone with its viewport.
struct PhoneActiveStream: Identifiable, Hashable {
    let name: String
    let zoom: CGFloat
    let centerX: CGFloat
    let centerY: CGFloat
    var id: String { name }
}

/// Streaming modes that mirror the iPhone side.
enum StreamMode: String, CaseIterable, Identifiable {
    case videoAndAudio = "videoAndAudio"
    case videoOnly = "videoOnly"
    case audioOnly = "audioOnly"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .videoAndAudio: return "Video + Audio"
        case .videoOnly: return "Video"
        case .audioOnly: return "Audio"
        }
    }

    var icon: String {
        switch self {
        case .videoAndAudio: return "video.and.waveform"
        case .videoOnly: return "video"
        case .audioOnly: return "waveform"
        }
    }
}

/// Manages WatchConnectivity on the Watch side.
/// Receives tagged data payloads: 0x01 = JPEG frame, 0x02 = MP3 audio chunk.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published var availableStreams: [String] = []
    /// Streams currently visible on the iPhone, with their viewport (zoom/pan).
    @Published var phoneActiveStreams: [PhoneActiveStream] = []
    @Published var isPhoneReachable = false
    @Published var latestSnapshot: UIImage?
    @Published var subscribedStream: String?
    @Published var currentMode: StreamMode = .videoAndAudio

    /// Pushed from iPhone when it wants the Watch to show a specific camera.
    /// Includes initial viewport (zoom, centerX, centerY).
    @Published var pushedCamera: PushedCamera?

    /// True while waiting for subscribe confirmation from iPhone.
    @Published var isSubscribing = false

    /// Fix #2: Timestamp of last received video frame for staleness detection.
    @Published var lastFrameTime: Date?

    /// Fix #3: True when iPhone has signalled it's backgrounded.
    @Published var isStreamPaused = false

    struct PushedCamera: Equatable {
        let streamName: String
        let zoom: CGFloat
        let centerX: CGFloat
        let centerY: CGFloat
    }

    let audioPlayer = AudioChunkPlayer()

    private var session: WCSession?
    private var subscribeRetryTask: Task<Void, Never>?

    /// Monotonic counter to prevent message ordering races.
    /// Included in subscribe messages so the iPhone can reject stale requests.
    private var subscribeGeneration: UInt64 = 0

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        self.session = s
    }

    /// Apply watch settings from applicationContext (prefixed with "watch_")
    func parsePhoneActiveStreams(_ entries: [[String: Any]]) -> [PhoneActiveStream] {
        entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            return PhoneActiveStream(
                name: name,
                zoom: entry["zoom"] as? CGFloat ?? 1,
                centerX: entry["centerX"] as? CGFloat ?? 0.5,
                centerY: entry["centerY"] as? CGFloat ?? 0.5
            )
        }
    }

    func applySettingsFromContext(_ ctx: [String: Any]) {
        let s = WatchSettings.shared
        if let v = ctx["watch_glanceModeEnabled"] as? Bool { s.glanceModeEnabled = v }
        if let v = ctx["watch_defaultStreamMode"] as? String { s.defaultStreamMode = v }
        if let v = ctx["watch_streamTimeoutMinutes"] as? Int { s.streamTimeoutMinutes = v }
        if let v = ctx["watch_glanceDefaultCamera"] as? String { s.glanceDefaultCamera = v }
    }

    /// Apply watch settings from a direct message
    func applySettings(_ settings: [String: Any]) {
        let s = WatchSettings.shared
        if let v = settings["glanceModeEnabled"] as? Bool { s.glanceModeEnabled = v }
        if let v = settings["defaultStreamMode"] as? String { s.defaultStreamMode = v }
        if let v = settings["streamTimeoutMinutes"] as? Int { s.streamTimeoutMinutes = v }
        if let v = settings["glanceDefaultCamera"] as? String { s.glanceDefaultCamera = v }
        log.info("Watch settings applied from iPhone")
    }

    func syncSettingsToPhone() {
        guard let session, session.isReachable else { return }
        let s = WatchSettings.shared
        session.sendMessage([
            "request": "setWatchSettings",
            "glanceModeEnabled": s.glanceModeEnabled,
            "defaultStreamMode": s.defaultStreamMode,
            "streamTimeoutMinutes": s.streamTimeoutMinutes,
            "glanceDefaultCamera": s.glanceDefaultCamera,
        ], replyHandler: nil, errorHandler: { error in
            log.warning("Failed to sync settings to phone: \(error)")
        })
    }

    func syncWristBehaviorToPhone(_ behavior: String) {
        guard let session else { return }
        // Immediate delivery
        if session.isReachable {
            session.sendMessage(["request": "setWristBehavior", "value": behavior], replyHandler: nil, errorHandler: { error in
                log.warning("Failed to sync wrist behavior: \(error)")
            })
        }
        // Persistent delivery via applicationContext
        do {
            var ctx = session.applicationContext
            ctx["wristBehavior"] = behavior
            ctx["timestamp"] = Date().timeIntervalSince1970
            try session.updateApplicationContext(ctx)
        } catch {
            log.warning("Failed to update applicationContext: \(error)")
        }
    }

    func requestStreamsFromPhone() {
        guard let session, session.isReachable else { return }
        session.sendMessage(["request": "getStreams"], replyHandler: { reply in
            Task { @MainActor in
                if let streams = reply["streams"] as? [String] {
                    self.availableStreams = streams
                }
                if let selected = reply["selectedStreams"] as? [[String: Any]] {
                    self.phoneActiveStreams = self.parsePhoneActiveStreams(selected)
                }
            }
        }, errorHandler: { error in
            log.warning("Failed to request streams: \(error)")
        })
    }

    func subscribe(to streamName: String, mode: StreamMode, zoom: CGFloat = 1.0, centerX: CGFloat = 0.5, centerY: CGFloat = 0.5) {
        subscribeRetryTask?.cancel()
        subscribeRetryTask = nil

        subscribeGeneration &+= 1
        subscribedStream = streamName
        currentMode = mode
        latestSnapshot = nil
        isSubscribing = true
        lastFrameTime = nil
        isStreamPaused = false

        if mode != .videoOnly {
            audioPlayer.start()
        }

        sendSubscribe(streamName: streamName, mode: mode, zoom: zoom, centerX: centerX, centerY: centerY, attempt: 1)
    }

    /// Sends the subscribe message with a reply handler for confirmation.
    /// Retries up to 3 times with exponential backoff on failure/timeout.
    private func sendSubscribe(streamName: String, mode: StreamMode, zoom: CGFloat, centerX: CGFloat, centerY: CGFloat, attempt: Int) {
        guard let session, session.isReachable else {
            if attempt <= 3 {
                scheduleRetry(streamName: streamName, mode: mode, zoom: zoom, centerX: centerX, centerY: centerY, attempt: attempt)
            } else {
                log.error("Subscribe failed after \(attempt) attempts — phone not reachable")
                isSubscribing = false
            }
            return
        }

        session.sendMessage(
            [
                "request": "subscribe",
                "streamName": streamName,
                "mode": mode.rawValue,
                "zoom": Double(zoom),
                "centerX": Double(centerX),
                "centerY": Double(centerY),
                "generation": subscribeGeneration
            ],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    guard let self, self.subscribedStream == streamName else { return }
                    if reply["status"] as? String == "ok" {
                        log.info("Subscribe confirmed for \(streamName)")
                        self.isSubscribing = false
                    }
                }
            },
            errorHandler: { [weak self] error in
                log.error("Subscribe send failed: \(error)")
                Task { @MainActor in
                    guard let self, self.subscribedStream == streamName else { return }
                    if attempt <= 3 {
                        self.scheduleRetry(streamName: streamName, mode: mode, zoom: zoom, centerX: centerX, centerY: centerY, attempt: attempt)
                    } else {
                        self.isSubscribing = false
                    }
                }
            }
        )

        // Timeout: if no reply within 5 seconds, retry
        subscribeRetryTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, subscribedStream == streamName, isSubscribing else { return }
            log.warning("Subscribe timeout for \(streamName), attempt \(attempt)")
            if attempt <= 3 {
                sendSubscribe(streamName: streamName, mode: mode, zoom: zoom, centerX: centerX, centerY: centerY, attempt: attempt + 1)
            } else {
                isSubscribing = false
            }
        }
    }

    private func scheduleRetry(streamName: String, mode: StreamMode, zoom: CGFloat, centerX: CGFloat, centerY: CGFloat, attempt: Int) {
        let delay = UInt64(pow(2.0, Double(attempt))) // 2s, 4s, 8s
        subscribeRetryTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, subscribedStream == streamName else { return }
            sendSubscribe(streamName: streamName, mode: mode, zoom: zoom, centerX: centerX, centerY: centerY, attempt: attempt + 1)
        }
    }

    func changeMode(_ mode: StreamMode) {
        guard let stream = subscribedStream else { return }
        if mode == .videoOnly {
            audioPlayer.stop()
        } else if !audioPlayer.isPlaying {
            audioPlayer.start()
        }
        // Preserve existing snapshot during mode change to avoid black flash on wrist-raise.
        let preservedSnapshot = latestSnapshot
        let preservedFrameTime = lastFrameTime
        subscribe(to: stream, mode: mode)
        if preservedSnapshot != nil {
            latestSnapshot = preservedSnapshot
            lastFrameTime = preservedFrameTime
        }
    }

    func sendViewport(zoom: CGFloat, centerX: CGFloat, centerY: CGFloat) {
        guard let session, session.isReachable else { return }
        session.sendMessage(
            [
                "request": "viewport",
                "zoom": Double(zoom),
                "centerX": Double(centerX),
                "centerY": Double(centerY)
            ],
            replyHandler: nil,
            errorHandler: { error in
                log.error("Viewport update failed: \(error)")
            }
        )
    }

    func unsubscribe() {
        subscribeRetryTask?.cancel()
        subscribeRetryTask = nil

        let wasSubscribed = subscribedStream != nil
        subscribedStream = nil
        latestSnapshot = nil
        isSubscribing = false
        lastFrameTime = nil
        isStreamPaused = false
        audioPlayer.stop()

        guard wasSubscribed, let session, session.isReachable else { return }
        session.sendMessage(
            ["request": "unsubscribe"],
            replyHandler: nil,
            errorHandler: { error in
                log.error("Unsubscribe failed: \(error)")
            }
        )
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        log.info("WCSession activated: \(String(describing: activationState))")
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
            let ctx = session.receivedApplicationContext
            if let streams = ctx["streams"] as? [String], !streams.isEmpty {
                self.availableStreams = streams
            } else if session.isReachable {
                self.requestStreamsFromPhone()
            }
            if let selected = ctx["selectedStreams"] as? [[String: Any]] {
                self.phoneActiveStreams = self.parsePhoneActiveStreams(selected)
            }
            // Restore settings from applicationContext on cold launch
            if let behavior = ctx["wristBehavior"] as? String {
                WatchSettings.shared.wristBehavior = behavior
            }
            self.applySettingsFromContext(ctx)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("Phone reachability: \(session.isReachable)")
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
            if session.isReachable && self.availableStreams.isEmpty {
                self.requestStreamsFromPhone()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            if let streams = applicationContext["streams"] as? [String] {
                self.availableStreams = streams
            }
            if let selected = applicationContext["selectedStreams"] as? [[String: Any]] {
                self.phoneActiveStreams = self.parsePhoneActiveStreams(selected)
            }
            if let behavior = applicationContext["wristBehavior"] as? String {
                WatchSettings.shared.wristBehavior = behavior
            }
            self.applySettingsFromContext(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        replyHandler(Data())
        handleIncomingData(messageData)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        handleIncomingData(messageData)
    }

    private nonisolated func handleIncomingData(_ messageData: Data) {
        guard messageData.count > 1, let tag = messageData.first else { return }
        let payload = messageData.dropFirst()

        switch tag {
        case 0x01: // Video frame (JPEG)
            guard let image = UIImage(data: Data(payload)) else { return }
            Task { @MainActor in
                self.latestSnapshot = image
                self.lastFrameTime = Date()
                self.isStreamPaused = false
            }
        case 0x02: // Audio chunk (MP3)
            Task { @MainActor in
                self.audioPlayer.enqueue(mp3Data: Data(payload))
            }
        default:
            break
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let action = message["action"] as? String else { return }
        Task { @MainActor in
            switch action {
            case "showCamera":
                guard let streamName = message["streamName"] as? String else { return }
                self.pushedCamera = PushedCamera(
                    streamName: streamName,
                    zoom: message["zoom"] as? CGFloat ?? 1.0,
                    centerX: message["centerX"] as? CGFloat ?? 0.5,
                    centerY: message["centerY"] as? CGFloat ?? 0.5
                )
            case "streamPaused":
                self.isStreamPaused = true
                log.info("iPhone stream paused (backgrounded)")
            case "streamResumed":
                self.isStreamPaused = false
                log.info("iPhone stream resumed")
            case "streamsUpdate":
                if let streams = message["streams"] as? [String] {
                    self.availableStreams = streams
                }
                if let selected = message["selectedStreams"] as? [[String: Any]] {
                    self.phoneActiveStreams = self.parsePhoneActiveStreams(selected)
                }
            case "wristBehavior":
                if let value = message["value"] as? String {
                    WatchSettings.shared.wristBehavior = value
                    log.info("Wrist behavior updated: \(value)")
                }
            case "syncSettings":
                self.applySettings(message)
            default:
                break
            }
        }
    }
}
