import Foundation
import WatchConnectivity
import WebRTC
import Combine
import os

private let log = Logger(subsystem: "works.rainn.tilecam", category: "WatchSession")

/// Manages WatchConnectivity on the iPhone side.
/// Streams periodic JPEG snapshots from an RTCVideoTrack to the paired Apple Watch.
@MainActor
final class PhoneSessionManager: NSObject, ObservableObject {
    static let shared = PhoneSessionManager()

    @Published var isWatchReachable = false

    private var session: WCSession?
    private var registeredClients: [String: WebRTCClient] = [:]
    private var snapshotRenderer: SnapshotRenderer?
    private var currentTrack: RTCVideoTrack?
    private var watchedStreamName: String?
    private var trackObservation: AnyCancellable?

    // For streams not currently displayed on iPhone
    private var dedicatedClient: WebRTCClient?
    private var go2rtcService: Go2RTCService?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        self.session = s
    }

    func updateService(_ service: Go2RTCService?) {
        self.go2rtcService = service
    }

    func updateAvailableStreams(_ streams: [String]) {
        guard let session, session.activationState == .activated else { return }
        do {
            try session.updateApplicationContext([
                "streams": streams,
                "timestamp": Date().timeIntervalSince1970
            ])
        } catch {
            log.error("Failed to update application context: \(error)")
        }
    }

    // MARK: - Client Registration

    func registerClient(_ client: WebRTCClient, for streamName: String) {
        registeredClients[streamName] = client
        if watchedStreamName == streamName {
            attachRenderer(to: client)
        }
    }

    func unregisterClient(for streamName: String) {
        if watchedStreamName == streamName {
            detachRenderer()
        }
        registeredClients.removeValue(forKey: streamName)
    }

    /// Send a specific camera to the Watch (triggered from iPhone UI)
    func sendCameraToWatch(streamName: String) {
        guard let session, session.isReachable else { return }
        session.sendMessage(
            ["action": "showCamera", "streamName": streamName],
            replyHandler: nil
        )
    }

    // MARK: - Snapshot Streaming

    private func subscribeToStream(_ streamName: String) {
        log.info("Watch subscribing to: \(streamName)")
        unsubscribeFromStream()
        watchedStreamName = streamName

        if let client = registeredClients[streamName] {
            attachRenderer(to: client)
        } else if let service = go2rtcService {
            log.info("Creating dedicated WebRTC client for Watch: \(streamName)")
            let client = WebRTCClient(service: service, streamName: streamName)
            dedicatedClient = client
            Task {
                await client.connect()
            }
            trackObservation = client.$videoTrack
                .compactMap { $0 }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.attachRenderer(to: client)
                }
        }
    }

    private func unsubscribeFromStream() {
        detachRenderer()
        watchedStreamName = nil
        trackObservation?.cancel()
        trackObservation = nil
        dedicatedClient?.disconnect()
        dedicatedClient = nil
    }

    private func attachRenderer(to client: WebRTCClient) {
        detachRenderer()

        guard let videoTrack = client.videoTrack else {
            trackObservation = client.$videoTrack
                .compactMap { $0 }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.attachRenderer(to: client)
                }
            return
        }

        let renderer = SnapshotRenderer()
        renderer.onSnapshot = { data in
            guard WCSession.default.isReachable else { return }
            WCSession.default.sendMessageData(data, replyHandler: nil, errorHandler: nil)
        }
        videoTrack.add(renderer)
        snapshotRenderer = renderer
        currentTrack = videoTrack
        log.info("Snapshot renderer attached for \(client.streamName)")
    }

    private func detachRenderer() {
        if let renderer = snapshotRenderer, let track = currentTrack {
            track.remove(renderer)
        }
        snapshotRenderer = nil
        currentTrack = nil
        trackObservation?.cancel()
        trackObservation = nil
    }
}

// MARK: - WCSessionDelegate

extension PhoneSessionManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        log.info("WCSession activated: \(String(describing: activationState))")
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("Watch reachability: \(session.isReachable)")
        Task { @MainActor in
            self.isWatchReachable = session.isReachable
            if !session.isReachable {
                self.unsubscribeFromStream()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let request = message["request"] as? String else { return }
        Task { @MainActor in
            switch request {
            case "subscribe":
                if let name = message["streamName"] as? String {
                    self.subscribeToStream(name)
                }
            case "unsubscribe":
                self.unsubscribeFromStream()
            default:
                break
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let request = message["request"] as? String else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            switch request {
            case "subscribe":
                if let name = message["streamName"] as? String {
                    self.subscribeToStream(name)
                }
                replyHandler(["status": "ok"])
            case "unsubscribe":
                self.unsubscribeFromStream()
                replyHandler(["status": "ok"])
            default:
                replyHandler([:])
            }
        }
    }
}
