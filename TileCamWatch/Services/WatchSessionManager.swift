import Foundation
import WatchConnectivity
import UIKit
import os

private let log = Logger(subsystem: "works.rainn.tilecam.watch", category: "Session")

/// Manages WatchConnectivity on the Watch side.
/// Receives stream lists and JPEG snapshot data from the paired iPhone.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published var availableStreams: [String] = []
    @Published var isPhoneReachable = false
    @Published var latestSnapshot: UIImage?
    @Published var subscribedStream: String?

    /// Pushed from iPhone when it wants the Watch to show a specific camera
    @Published var pushedStreamName: String?

    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        self.session = s
    }

    func subscribe(to streamName: String) {
        subscribedStream = streamName
        latestSnapshot = nil
        guard let session, session.isReachable else { return }
        session.sendMessage(
            ["request": "subscribe", "streamName": streamName],
            replyHandler: nil,
            errorHandler: { error in
                log.error("Subscribe failed: \(error)")
            }
        )
    }

    func unsubscribe() {
        let wasSubscribed = subscribedStream != nil
        subscribedStream = nil
        latestSnapshot = nil
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
            // Load streams from application context if available
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
        // JPEG snapshot data from iPhone
        guard let image = UIImage(data: messageData) else { return }
        Task { @MainActor in
            self.latestSnapshot = image
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
