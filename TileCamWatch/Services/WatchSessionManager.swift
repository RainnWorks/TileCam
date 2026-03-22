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

    /// Pushed from iPhone when it wants the Watch to show a specific camera
    @Published var pushedStreamName: String?

    let audioPlayer = AudioChunkPlayer()

    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        self.session = s
    }

    func subscribe(to streamName: String, mode: StreamMode) {
        subscribedStream = streamName
        currentMode = mode
        latestSnapshot = nil

        if mode != .videoOnly {
            audioPlayer.start()
        }

        guard let session, session.isReachable else { return }
        session.sendMessage(
            [
                "request": "subscribe",
                "streamName": streamName,
                "mode": mode.rawValue
            ],
            replyHandler: nil,
            errorHandler: { error in
                log.error("Subscribe failed: \(error)")
            }
        )
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
        let wasSubscribed = subscribedStream != nil
        subscribedStream = nil
        latestSnapshot = nil
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
        if let action = message["action"] as? String, action == "showCamera",
           let streamName = message["streamName"] as? String {
            Task { @MainActor in
                self.pushedStreamName = streamName
            }
        }
    }
}
