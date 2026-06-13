import Foundation
import WebRTC
import Combine
import os

private let log = Logger(subsystem: "works.rainn.tilecam", category: "WebRTC")

/// Manages a single WebRTC peer connection to a go2rtc stream.
/// Each stream gets its own WebRTCClient instance, allowing multiple
/// simultaneous video+audio feeds (bypassing iOS single-video limitation).
///
/// Includes automatic retry with exponential backoff on failure/disconnect.
@MainActor
final class WebRTCClient: NSObject, ObservableObject {
    private var peerConnection: RTCPeerConnection?
    private let factory: RTCPeerConnectionFactory
    private let service: Go2RTCService
    let streamName: String

    @Published var videoTrack: RTCVideoTrack?
    @Published var audioTrack: RTCAudioTrack?
    /// True once the video view has actually decoded and rendered a frame.
    /// A `videoTrack` object can exist long before (or without) any media flowing,
    /// so this is the real "video is live" signal used to gate the spinner.
    @Published var videoReady = false
    /// True when negotiation completed but the answer carried no usable audio track.
    @Published var audioUnavailable = false
    @Published var audioLevel: Float = 0
    @Published var connectionState: RTCIceConnectionState = .new
    @Published var error: String?
    @Published var isRetrying = false
    @Published private(set) var retryCount = 0

    var isAudioEnabled: Bool = true {
        didSet { audioTrack?.isEnabled = isAudioEnabled }
    }

    private var retryTask: Task<Void, Never>?
    private var audioLevelTimer: Task<Void, Never>?
    private var frameWatchdog: Task<Void, Never>?
    private var isManuallyDisconnected = false

    private static let maxRetryDelay: TimeInterval = 30
    private static let baseRetryDelay: TimeInterval = 1
    private static let maxRetryCount = 20
    /// How long to wait for a first decoded frame after negotiation before
    /// treating the connection as wedged and retrying.
    private static let firstFrameTimeout: TimeInterval = 10

    init(service: Go2RTCService, streamName: String) {
        self.factory = WebRTCFactory.shared.factory
        self.service = service
        self.streamName = streamName
        super.init()
    }

    /// Trigger lazy factory initialization early (call from background thread)
    nonisolated static func warmUp() {
        WebRTCFactory.shared.ensureReady()
    }

    func connect() async {
        log.info("[\(self.streamName)] connect() called")
        isManuallyDisconnected = false
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
        isRetrying = false
        error = nil

        await attemptConnection()
    }

    /// Called by the video view once a real decoded frame has rendered.
    func markVideoReady() {
        guard !videoReady else { return }
        log.info("[\(self.streamName)] First video frame rendered")
        videoReady = true
        frameWatchdog?.cancel()
        frameWatchdog = nil
    }

    /// Schedules a retry if no decoded video frame arrives within the timeout.
    /// Guards against the "ICE connected but no media flows" wedge where the
    /// peer connection never reports failure.
    private func startFrameWatchdog() {
        frameWatchdog?.cancel()
        frameWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstFrameTimeout))
            guard let self, !Task.isCancelled else { return }
            guard !self.videoReady, self.videoTrack != nil else { return }
            log.warning("[\(self.streamName)] No video frame after \(Self.firstFrameTimeout)s — retrying")
            self.error = self.error ?? "No video received"
            self.scheduleRetry()
        }
    }

    private func attemptConnection() async {
        log.info("[\(self.streamName)] attemptConnection (retry #\(self.retryCount))")
        tearDownPeerConnection()

        connectionState = .new

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            log.error("[\(self.streamName)] Failed to create RTCPeerConnection")
            error = "Failed to create peer connection"
            scheduleRetry()
            return
        }
        self.peerConnection = pc
        log.info("[\(self.streamName)] PeerConnection created")

        let videoTransceiver = pc.addTransceiver(of: .video)
        videoTransceiver?.setDirection(.recvOnly, error: nil)
        log.info("[\(self.streamName)] Video transceiver added (recvOnly)")

        let audioTransceiver = pc.addTransceiver(of: .audio)
        audioTransceiver?.setDirection(.recvOnly, error: nil)
        log.info("[\(self.streamName)] Audio transceiver added (recvOnly)")

        pc.delegate = self

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true",
                "OfferToReceiveAudio": "true"
            ],
            optionalConstraints: nil
        )

        do {
            log.info("[\(self.streamName)] Creating SDP offer...")
            let offer = try await pc.offer(for: offerConstraints)
            log.info("[\(self.streamName)] SDP offer created (\(offer.sdp.count) bytes)")

            try await pc.setLocalDescription(offer)
            log.info("[\(self.streamName)] Local description set")

            log.info("[\(self.streamName)] Negotiating with go2rtc...")
            let answerSDP = try await service.negotiateWebRTC(
                streamName: streamName,
                offerSDP: offer.sdp
            )
            log.info("[\(self.streamName)] Got SDP answer (\(answerSDP.count) bytes)")
            log.info("[\(self.streamName)] Full answer SDP:\n\(answerSDP, privacy: .public)")

            let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
            try await pc.setRemoteDescription(answer)
            log.info("[\(self.streamName)] Remote description set — waiting for ICE")

            // Extract tracks from transceivers (unified plan)
            for transceiver in pc.transceivers {
                let track = transceiver.receiver.track
                let mediaType = transceiver.mediaType == .audio ? "audio"
                    : transceiver.mediaType == .video ? "video" : "other"
                log.info("[\(self.streamName)] Transceiver mediaType=\(mediaType, privacy: .public) trackPresent=\(track != nil) trackKind=\(track?.kind ?? "nil", privacy: .public) readyState=\(track?.readyState.rawValue ?? -1)")
                if let videoTrack = track as? RTCVideoTrack {
                    log.info("[\(self.streamName)] Found video track, isEnabled=\(videoTrack.isEnabled)")
                    videoTrack.isEnabled = true
                    self.videoTrack = videoTrack
                } else if let audioTrack = track as? RTCAudioTrack {
                    log.info("[\(self.streamName)] Found audio track, setting isEnabled=\(self.isAudioEnabled)")
                    audioTrack.isEnabled = self.isAudioEnabled
                    self.audioTrack = audioTrack
                    startAudioLevelPolling()
                }
            }

            // The answer is fully applied here: if no audio track was attached,
            // this stream has no usable audio (go2rtc returned video-only).
            audioUnavailable = (audioTrack == nil)
            if audioUnavailable {
                log.warning("[\(self.streamName)] No audio track in answer — audio unavailable")
            }

            retryCount = 0
            error = nil

            if videoTrack != nil {
                startFrameWatchdog()
            }
        } catch is CancellationError {
            log.info("[\(self.streamName)] Connection cancelled")
        } catch {
            log.error("[\(self.streamName)] Connection failed: \(error)")
            self.error = error.localizedDescription
            scheduleRetry()
        }
    }

    private func startAudioLevelPolling() {
        audioLevelTimer?.cancel()
        audioLevelTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled, let pc = self.peerConnection else { continue }
                pc.statistics { report in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        var maxLevel: Float = 0
                        for (_, stats) in report.statistics {
                            if stats.type == "inbound-rtp",
                               stats.values["kind"] as? String == "audio",
                               let level = stats.values["audioLevel"] as? Double {
                                maxLevel = max(maxLevel, Float(level))
                            }
                        }
                        self.audioLevel = maxLevel
                    }
                }
            }
        }
    }

    private func tearDownPeerConnection() {
        audioLevelTimer?.cancel()
        audioLevelTimer = nil
        frameWatchdog?.cancel()
        frameWatchdog = nil
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        videoTrack = nil
        audioTrack = nil
        videoReady = false
        audioUnavailable = false
        audioLevel = 0
    }

    func disconnect() {
        isManuallyDisconnected = true
        retryTask?.cancel()
        retryTask = nil
        audioLevelTimer?.cancel()
        audioLevelTimer = nil
        frameWatchdog?.cancel()
        frameWatchdog = nil
        isRetrying = false
        retryCount = 0
        tearDownPeerConnection()
        connectionState = .closed
    }

    // MARK: - Retry Logic

    private func scheduleRetry() {
        guard !isManuallyDisconnected else { return }
        guard retryCount < Self.maxRetryCount else {
            log.error("[\(self.streamName)] Max retries (\(Self.maxRetryCount)) reached, giving up")
            error = "Connection failed after \(Self.maxRetryCount) attempts"
            isRetrying = false
            return
        }

        retryCount += 1
        isRetrying = true

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (capped)
        let delay = min(
            Self.baseRetryDelay * pow(2, Double(retryCount - 1)),
            Self.maxRetryDelay
        )

        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                await self.attemptConnection()
            } catch {
                // Cancelled - do nothing
            }
        }
    }

    private func handleConnectionFailure() {
        guard !isManuallyDisconnected else { return }
        if error == nil {
            error = "Connection lost"
        }
        scheduleRetry()
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        log.info("[delegate] Signaling state: \(String(describing: stateChanged))")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        log.info("[delegate] Stream added — video tracks: \(stream.videoTracks.count), audio tracks: \(stream.audioTracks.count)")
        Task { @MainActor in
            if let track = stream.videoTracks.first {
                log.info("[\(self.streamName)] Video track assigned")
                self.videoTrack = track
            }
            if let track = stream.audioTracks.first {
                log.info("[\(self.streamName)] Audio track assigned, isEnabled=\(self.isAudioEnabled)")
                track.isEnabled = self.isAudioEnabled
                self.audioTrack = track
                // Audio actually arrived via this delegate path: clear any
                // earlier "unavailable" marker set from the transceiver loop.
                self.audioUnavailable = false
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        log.info("[delegate] Stream removed")
    }

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        log.info("[delegate] Should negotiate")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        log.info("[delegate] ICE connection state: \(String(describing: newState))")
        Task { @MainActor in
            self.connectionState = newState

            switch newState {
            case .connected, .completed:
                log.info("[\(self.streamName)] ICE connected!")
                self.isRetrying = false
                self.retryCount = 0
                self.error = nil
            case .failed:
                log.error("[\(self.streamName)] ICE failed")
                self.error = self.error ?? "ICE connection failed"
                self.handleConnectionFailure()
            case .disconnected:
                log.warning("[\(self.streamName)] ICE disconnected — waiting 3s grace period")
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    if self.connectionState == .disconnected {
                        log.warning("[\(self.streamName)] Still disconnected after grace period, retrying")
                        self.handleConnectionFailure()
                    }
                }
            case .new, .checking, .closed:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        log.info("[delegate] ICE gathering state: \(String(describing: newState))")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        log.info("[delegate] ICE candidate generated: \(candidate.sdp.prefix(80))...")
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        log.info("[delegate] Data channel opened")
    }
}

// MARK: - Async helpers for RTCPeerConnection
extension RTCPeerConnection {
    func offer(for constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            self.offer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error) }
                else if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: Go2RTCError.negotiationFailed) }
            }
        }
    }

    func setLocalDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func setRemoteDescription(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
