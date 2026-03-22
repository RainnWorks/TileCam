import Foundation
import WatchConnectivity
import UIKit
import os

private let log = Logger(subsystem: "works.rainn.tilecam.watch", category: "Session")

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
    @Published var isPhoneReachable = false
    @Published var latestSnapshot: UIImage?
    @Published var subscribedStream: String?
    @Published var currentMode: StreamMode = .videoAndAudio

    /// Pushed from iPhone when it wants the Watch to show a specific camera.
    /// Includes initial viewport (zoom, centerX, centerY).
    @Published var pushedCamera: PushedCamera?

    /// True while waiting for subscribe confirmation from iPhone.
    @Published var isSubscribing = false

    struct PushedCamera: Equatable {
        let streamName: String
        let zoom: CGFloat
        let centerX: CGFloat
        let centerY: CGFloat
    }

    let audioPlayer = AudioChunkPlayer()

    private var session: WCSession?
    private var subscribeRetryTask: Task<Void, Never>?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        self.session = s
    }

    func subscribe(to streamName: String, mode: StreamMode, zoom: CGFloat = 1.0, centerX: CGFloat = 0.5, centerY: CGFloat = 0.5) {
        subscribeRetryTask?.cancel()
        subscribeRetryTask = nil

        subscribedStream = streamName
        currentMode = mode
        latestSnapshot = nil
        isSubscribing = true

        if mode != .videoOnly {
            audioPlayer.start()
        }

        sendSubscribe(streamName: streamName, mode: mode, zoom: zoom, centerX: centerX, centerY: centerY, attempt: 1)
    }

    /// Sends the subscribe message with a reply handler for confirmation.
    /// Retries up to 3 times with exponential backoff on failure/timeout.
    private func sendSubscribe(streamName: String, mode: StreamMode, zoom: CGFloat, centerX: CGFloat, centerY: CGFloat, attempt: Int) {
        guard let session, session.isReachable else {
            // Phone not reachable — schedule retry
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
                "centerY": Double(centerY)
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
        subscribe(to: stream, mode: mode)
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
            if let streams = ctx["streams"] as? [String] {
                self.availableStreams = streams
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("Phone reachability: \(session.isReachable)")
        Task { @MainActor in
            self.isPhoneReachable = session.isReachable
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        if let streams = applicationContext["streams"] as? [String] {
            Task { @MainActor in
                self.availableStreams = streams
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard messageData.count > 1, let tag = messageData.first else { return }
        let payload = messageData.dropFirst()

        switch tag {
        case 0x01: // Video frame (JPEG)
            guard let image = UIImage(data: Data(payload)) else { return }
            Task { @MainActor in
                self.latestSnapshot = image
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
            if action == "showCamera", let streamName = message["streamName"] as? String {
                self.pushedCamera = PushedCamera(
                    streamName: streamName,
                    zoom: message["zoom"] as? CGFloat ?? 1.0,
                    centerX: message["centerX"] as? CGFloat ?? 0.5,
                    centerY: message["centerY"] as? CGFloat ?? 0.5
                )
            }
        }
    }
}
