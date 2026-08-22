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
    /// True once the stream has failed to connect `unreachableThreshold` times in a
    /// row. Surfaced as a deliberate "camera unreachable" state instead of an endless
    /// spinner, while retries keep running underneath so it auto-recovers when the
    /// upstream source returns. Cleared on the next successful connection.
    @Published var isUnreachable = false

    var isAudioEnabled: Bool = true {
        didSet { audioTrack?.isEnabled = isAudioEnabled }
    }

    /// Consecutive connection-failure count (reset on any success). Distinct from
    /// `retryCount` only in that it is the signal for the unreachable state; both
    /// advance together but are reset at the same success points.
    private var consecutiveFailures = 0

    /// Whether the negotiated answer expects to deliver video (the video
    /// transceiver's currentDirection is recvOnly/sendRecv). Set per attempt.
    /// Drives the first-frame watchdog so we keep restarting a stream that
    /// negotiated video but renders no frame — even if the video track never
    /// attached (the audio-came-through-but-no-video wedge). Stays false for
    /// audio-only cameras so they are never retried forever.
    private var videoExpected = false

    private var retryTask: Task<Void, Never>?
    private var audioLevelTimer: Task<Void, Never>?
    private var frameWatchdog: Task<Void, Never>?
    private var isManuallyDisconnected = false
    /// True from the moment a connection attempt starts until the peer connection
    /// is torn down (disconnect, or a retry that re-runs attemptConnection). Used to
    /// make `connect()` idempotent: a duplicate call while a connection is in-flight
    /// or already established must be a no-op, never a tear-down-and-restart.
    private var isActive = false

    private static let maxRetryDelay: TimeInterval = 30
    private static let baseRetryDelay: TimeInterval = 1
    private static let maxRetryCount = 20
    /// How many consecutive connection failures before the tile flips to the
    /// "camera unreachable" state. Small enough (3) that a genuinely dead source
    /// shows within the first few seconds of backoff, well before the 20-retry
    /// give-up — so a dead camera never masquerades as a slow-connecting one.
    private static let unreachableThreshold = 3
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
        // Idempotent: cold start rebuilds the tile once, re-running its `.task`
        // and firing connect() twice ~20ms apart. Tearing down a mid-negotiation
        // peer connection on the duplicate call ("set remote answer ... wrong
        // state: closed") re-rolls the track-attach race, so a duplicate connect()
        // while an attempt is in-flight or already connected is a no-op here.
        // A genuine reconnect goes through disconnect() (clears isActive) or the
        // retry path, so this guard never blocks recovery.
        guard !isActive else {
            log.info("[\(self.streamName)] connect() ignored — already active")
            return
        }
        log.info("[\(self.streamName)] connect() called")
        isActive = true
        isManuallyDisconnected = false
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
        consecutiveFailures = 0
        isRetrying = false
        isUnreachable = false
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
            guard !self.videoReady, self.videoExpected else { return }
            // The render view's first-frame signal (didChangeVideoSize) can be
            // missed on a same-resolution reconnect — the reused RTCMTLVideoView
            // never re-reports its size — which would loop this watchdog forever
            // on a stream that is actually playing. Before retrying, confirm with
            // the peer connection's own stats that no frames are decoding.
            if await self.isDecodingVideo() {
                guard !Task.isCancelled else { return }
                self.markVideoReady()
                return
            }
            log.warning("[\(self.streamName)] No video frame after \(Self.firstFrameTimeout)s — retrying")
            self.error = self.error ?? "No video received"
            self.scheduleRetry()
        }
    }

    /// Whether the current peer connection is actually decoding video frames,
    /// read straight from the inbound-rtp stats. Ground truth for "is it playing"
    /// that doesn't depend on the render view's one-shot size callback.
    private func isDecodingVideo() async -> Bool {
        guard let pc = peerConnection else { return false }
        let report: RTCStatisticsReport = await withCheckedContinuation { cont in
            pc.statistics { cont.resume(returning: $0) }
        }
        for stats in report.statistics.values {
            guard stats.type == "inbound-rtp" else { continue }
            let kind = (stats.values["kind"] as? String) ?? (stats.values["mediaType"] as? String)
            guard kind == "video" else { continue }
            if let decoded = stats.values["framesDecoded"] as? NSNumber, decoded.intValue > 0 {
                return true
            }
        }
        return false
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

            // Best-effort fast path: tracks are often already wired on the
            // receivers by the time setRemoteDescription returns. The canonical
            // assignment point is the unified-plan delegate (didStartReceiving /
            // didAddReceiver), which fires once libwebrtc has actually wired them.
            // Both routes funnel through the idempotent assign* helpers, so a track
            // attached here and re-reported by the delegate is a no-op.
            for transceiver in pc.transceivers {
                let track = transceiver.receiver.track
                let mediaType = transceiver.mediaType == .audio ? "audio"
                    : transceiver.mediaType == .video ? "video" : "other"
                log.info("[\(self.streamName)] Transceiver mediaType=\(mediaType, privacy: .public) trackPresent=\(track != nil) trackKind=\(track?.kind ?? "nil", privacy: .public) readyState=\(track?.readyState.rawValue ?? -1)")
                if let videoTrack = track as? RTCVideoTrack {
                    assignVideoTrack(videoTrack)
                } else if let audioTrack = track as? RTCAudioTrack {
                    assignAudioTrack(audioTrack)
                }
            }

            // Derive audio availability deterministically from the negotiated
            // answer (the transceiver's currentDirection), NOT from whether a
            // track object happened to be wired yet. This avoids latching a false
            // "unavailable" when audio is expected but the track arrives a beat
            // later via the delegate. Once a track is assigned, assignAudioTrack
            // clears this flag and it is never re-latched.
            audioUnavailable = !audioExpected(in: pc)
            if audioUnavailable {
                log.warning("[\(self.streamName)] Answer negotiated no audio direction — audio unavailable")
            }

            self.videoExpected = videoExpected(in: pc)

            retryCount = 0
            error = nil

            // Arm whenever the answer negotiated video, even if the track hasn't
            // attached yet: the "audio came through but no video" wedge is exactly
            // the case where video is expected but no track/frame ever arrives.
            if videoExpected {
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

    // MARK: - Track assignment (idempotent)

    /// Canonical, idempotent video-track assignment. Safe to call from the
    /// synchronous fast-path, the unified-plan delegates, and the legacy
    /// `didAdd stream` path — assigns only when the track actually changes.
    private func assignVideoTrack(_ track: RTCVideoTrack) {
        guard videoTrack !== track else { return }
        log.info("[\(self.streamName)] Video track assigned")
        track.isEnabled = true
        videoTrack = track
    }

    /// Canonical, idempotent audio-track assignment. On assignment it clears any
    /// earlier `audioUnavailable` marker, re-applies the current mute state, and
    /// starts level polling if it isn't already running.
    private func assignAudioTrack(_ track: RTCAudioTrack) {
        guard audioTrack !== track else { return }
        log.info("[\(self.streamName)] Audio track assigned, isEnabled=\(self.isAudioEnabled)")
        track.isEnabled = isAudioEnabled
        audioTrack = track
        // A real audio track arrived: it is by definition available.
        audioUnavailable = false
        if audioLevelTimer == nil {
            startAudioLevelPolling()
        }
    }

    /// Whether the negotiated answer expects to deliver audio, read from the
    /// audio transceiver's negotiated `currentDirection` (recvOnly / sendRecv).
    private func audioExpected(in pc: RTCPeerConnection) -> Bool {
        for transceiver in pc.transceivers where transceiver.mediaType == .audio {
            var direction: RTCRtpTransceiverDirection = .inactive
            // currentDirection returns NO if never negotiated / stopped.
            guard transceiver.currentDirection(&direction) else { continue }
            if direction == .recvOnly || direction == .sendRecv {
                return true
            }
        }
        return false
    }

    /// Whether the negotiated answer expects to deliver video, read from the
    /// video transceiver's negotiated `currentDirection` (recvOnly / sendRecv).
    private func videoExpected(in pc: RTCPeerConnection) -> Bool {
        for transceiver in pc.transceivers where transceiver.mediaType == .video {
            var direction: RTCRtpTransceiverDirection = .inactive
            // currentDirection returns NO if never negotiated / stopped.
            guard transceiver.currentDirection(&direction) else { continue }
            if direction == .recvOnly || direction == .sendRecv {
                return true
            }
        }
        return false
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
        videoExpected = false
        audioLevel = 0
    }

    func disconnect() {
        isManuallyDisconnected = true
        isActive = false
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

        // Count this failure for the unreachable state. Done before the max-retry
        // guard so the threshold is always reached, and kept retrying afterwards so
        // the camera auto-recovers when its upstream source comes back.
        consecutiveFailures += 1
        if consecutiveFailures >= Self.unreachableThreshold && !isUnreachable {
            log.warning("[\(self.streamName)] \(self.consecutiveFailures) consecutive failures — marking unreachable")
            isUnreachable = true
        }

        guard retryCount < Self.maxRetryCount else {
            log.error("[\(self.streamName)] Max retries (\(Self.maxRetryCount)) reached, giving up")
            error = "Connection failed after \(Self.maxRetryCount) attempts"
            isRetrying = false
            // We've stopped trying; allow a manual connect() (retry button) to
            // start a fresh attempt rather than no-op against a dead connection.
            isActive = false
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

    // Legacy Plan-B path. Unified plan does NOT reliably fire this; kept as a
    // best-effort fallback, funneled through the same idempotent helpers.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        log.info("[delegate] Stream added — video tracks: \(stream.videoTracks.count), audio tracks: \(stream.audioTracks.count)")
        let videoTrack = stream.videoTracks.first
        let audioTrack = stream.audioTracks.first
        Task { @MainActor in
            if let videoTrack { self.assignVideoTrack(videoTrack) }
            if let audioTrack { self.assignAudioTrack(audioTrack) }
        }
    }

    // MARK: Unified-plan track delivery (canonical assignment point)

    /// Fires once libwebrtc has wired the receiver's track for a transceiver —
    /// the reliable signal under unified plan that media is about to flow.
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        let track = transceiver.receiver.track
        log.info("[delegate] didStartReceivingOn mediaType=\(transceiver.mediaType.rawValue) trackKind=\(track?.kind ?? "nil", privacy: .public)")
        Task { @MainActor in
            if let videoTrack = track as? RTCVideoTrack {
                self.assignVideoTrack(videoTrack)
            } else if let audioTrack = track as? RTCAudioTrack {
                self.assignAudioTrack(audioTrack)
            }
        }
    }

    /// Fires when a receiver and its track are created (unified plan).
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        let track = rtpReceiver.track
        log.info("[delegate] didAddReceiver trackKind=\(track?.kind ?? "nil", privacy: .public)")
        Task { @MainActor in
            if let videoTrack = track as? RTCVideoTrack {
                self.assignVideoTrack(videoTrack)
            } else if let audioTrack = track as? RTCAudioTrack {
                self.assignAudioTrack(audioTrack)
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
                self.consecutiveFailures = 0
                self.isUnreachable = false
                self.error = nil
                // Cover the "ICE connected but no media flows" wedge where the
                // track is missing or attached-but-delivers-no-frame: if video
                // was negotiated and still isn't live, (re)arm the watchdog so a
                // silent video failure still drives a restart.
                if self.videoExpected, !self.videoReady, self.frameWatchdog == nil {
                    self.startFrameWatchdog()
                }
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
