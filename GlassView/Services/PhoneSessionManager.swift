import Foundation
import WatchConnectivity
import UIKit
import os

extension Notification.Name {
    static let wristBehaviorChangedFromWatch = Notification.Name("wristBehaviorChangedFromWatch")
    static let watchSettingsChangedFromWatch = Notification.Name("watchSettingsChangedFromWatch")
}

private let log = Logger(subsystem: "works.rainn.tilecam", category: "WatchSession")

/// Message type tags prefixed to sendMessageData payloads.
enum WatchDataTag: UInt8 {
    case videoFrame = 0x01
    case audioChunk = 0x02
}

/// Streaming modes the Watch can request.
enum WatchStreamMode: String {
    case videoAndAudio
    case videoOnly
    case audioOnly
}

/// Max payload size for WCSession sendMessageData (~62KB leaves headroom under the ~65KB limit).
private let maxWCMessageSize = 62_000

/// Lock-guarded boolean shared safely across executors (watchdog Task ↔ byte-loop).
/// Replaces captured-local `var` flags that would otherwise be a data race.
private final class AtomicFlag: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var value = false

    /// Sets the flag and returns its previous value.
    @discardableResult
    func set() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let old = value
        value = true
        return old
    }

    var isSet: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }
}

/// MJPEG frame buffer cap — drop malformed frames that never terminate.
private let maxFrameBufferSize = 512_000

/// Snapshot of viewport values for nonisolated crop work.
private struct ViewportSnapshot {
    let zoom: CGFloat
    let centerX: CGFloat
    let centerY: CGFloat

    var isCropping: Bool { zoom > 1.01 }
}

/// Manages WatchConnectivity on the iPhone side.
/// Streams JPEG snapshots and MP3 audio from go2rtc HTTP endpoints to the Watch.
/// The Watch controls its own viewport; iPhone just crops frames to match.
@MainActor
final class PhoneSessionManager: NSObject, ObservableObject {
    static let shared = PhoneSessionManager()

    @Published var isWatchReachable = false
    /// True when MJPEG streaming failed and we fell back to snapshot polling.
    @Published var isWatchStreamDegraded = false

    /// Whether the Apple Watch unlock IAP has been purchased. Source of truth is
    /// `StoreManager`, which calls `setWatchEntitlement(_:)` on every change.
    /// Gates all Watch subscribe paths — no purchase, no streaming.
    var isWatchUnlocked = false

    private var session: WCSession?
    private var go2rtcService: Go2RTCService?

    private var watchedStreamName: String?
    private var currentMode: WatchStreamMode = .videoAndAudio
    private var snapshotTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?

    /// Guards against zombie poller — incremented on each subscribe/unsubscribe cycle.
    private var streamGeneration: UInt64 = 0

    /// Last Watch subscribe generation received — rejects stale/reordered subscribe messages.
    private var lastWatchGeneration: UInt64 = 0

    /// Tracks last Watch subscription for BT blip recovery.
    /// When Bluetooth briefly drops and reconnects, we can restore the stream.
    private var lastWatchSubscription: (name: String, mode: WatchStreamMode)?

    /// Current viewport from Watch, used for cropping MJPEG frames.
    private var viewportZoom: CGFloat = 1.0
    private var viewportCenterX: CGFloat = 0.5
    private var viewportCenterY: CGFloat = 0.5

    /// Backpressure: true while a sendMessageData call is in-flight for video.
    private var videoSendInFlight = false

    /// URLSession used for the current MJPEG stream — invalidated on unsubscribe.
    private var mjpegSession: URLSession?
    /// URLSession used for the current audio stream — invalidated on unsubscribe.
    private var audioStreamSession: URLSession?

    /// Fix #9: Cached last viewport used for crop to skip redundant re-encodes.
    private var lastCropViewport: ViewportSnapshot?
    private var lastCroppedFrame: Data?

    /// Fix #3: Track whether app is backgrounded to notify Watch.
    private var isAppBackgrounded = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        self.session = s

        // Fix #3: Observe app lifecycle
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    func updateService(_ service: Go2RTCService?) {
        self.go2rtcService = service
    }

    private(set) var availableStreamNames: [String] = []

    private(set) var selectedStreamEntries: [[String: Any]] = []

    func updateAvailableStreams(_ streams: [String]) {
        availableStreamNames = streams
        syncStreamsToWatch()
    }

    func updateSelectedStreams(_ entries: [[String: Any]]) {
        selectedStreamEntries = entries
        syncStreamsToWatch()
    }

    private func syncStreamsToWatch() {
        guard let session, session.activationState == .activated else { return }
        let behavior = UserDefaults.standard.string(forKey: "wristBehavior") ?? "eco"
        do {
            try session.updateApplicationContext([
                "streams": availableStreamNames,
                "selectedStreams": selectedStreamEntries,
                "timestamp": Date().timeIntervalSince1970,
                "wristBehavior": behavior
            ])
        } catch {
            log.error("Failed to update application context: \(error)")
        }
        if session.isReachable {
            session.sendMessage([
                "action": "streamsUpdate",
                "streams": availableStreamNames,
                "selectedStreams": selectedStreamEntries
            ], replyHandler: nil, errorHandler: nil)
        }
    }

    /// Syncs the wrist-down behavior setting to the Watch via direct message + applicationContext.
    /// Dual-write ensures delivery: sendMessage for immediacy, applicationContext for persistence.
    func syncWristBehavior(_ behavior: String) {
        guard let session else { return }

        // Immediate delivery if Watch is reachable
        if session.isReachable {
            session.sendMessage(
                ["action": "wristBehavior", "value": behavior],
                replyHandler: nil,
                errorHandler: { error in log.error("wristBehavior sync failed: \(error)") }
            )
        }

        // Also update applicationContext for persistence (survives app restarts, delivered on cold launch)
        guard session.activationState == .activated else { return }
        var ctx = session.receivedApplicationContext
        ctx["wristBehavior"] = behavior
        ctx["timestamp"] = Date().timeIntervalSince1970
        do {
            try session.updateApplicationContext(ctx)
        } catch {
            log.error("Failed to update applicationContext with wristBehavior: \(error)")
        }
    }

    // MARK: - Watch Unlock Entitlement

    /// Records the Watch unlock entitlement and pushes it to the Watch. When the
    /// entitlement is revoked (refund / Family Sharing removal), tears down any
    /// in-flight Watch stream immediately so the Watch stops receiving frames.
    func setWatchEntitlement(_ unlocked: Bool) {
        isWatchUnlocked = unlocked
        syncWatchUnlocked(unlocked)
        if !unlocked {
            // Kill any active Watch stream right now — don't wait for the Watch
            // to notice and unsubscribe.
            unsubscribeFromStream(clearRecovery: true)
        }
    }

    /// Syncs the Watch unlock flag to the Watch via direct message + applicationContext.
    /// Dual-write mirrors `syncWristBehavior`: sendMessage for immediacy,
    /// applicationContext for persistence (survives restarts, delivered on cold launch).
    func syncWatchUnlocked(_ unlocked: Bool) {
        guard let session else { return }

        if session.isReachable {
            session.sendMessage(
                ["action": "watchUnlocked", "value": unlocked],
                replyHandler: nil,
                errorHandler: { error in log.error("watchUnlocked sync failed: \(error)") }
            )
        }

        guard session.activationState == .activated else { return }
        var ctx = session.receivedApplicationContext
        ctx["watchUnlocked"] = unlocked
        ctx["timestamp"] = Date().timeIntervalSince1970
        do {
            try session.updateApplicationContext(ctx)
        } catch {
            log.error("Failed to update applicationContext with watchUnlocked: \(error)")
        }
    }

    func syncWatchSettings(_ settings: [String: Any]) {
        guard let session else { return }
        // Immediate delivery
        if session.isReachable {
            var msg = settings
            msg["action"] = "syncSettings"
            session.sendMessage(msg, replyHandler: nil, errorHandler: { error in
                log.error("Watch settings sync failed: \(error)")
            })
        }
        // Persistent via applicationContext
        guard session.activationState == .activated else { return }
        var ctx = session.receivedApplicationContext
        for (key, value) in settings {
            ctx["watch_\(key)"] = value
        }
        ctx["timestamp"] = Date().timeIntervalSince1970
        do {
            try session.updateApplicationContext(ctx)
        } catch {
            log.error("Failed to update applicationContext with watch settings: \(error)")
        }
    }

    /// One-shot: send a camera + current viewport to the Watch.
    /// Watch auto-navigates and opens at the given zoom/pan.
    func sendCameraToWatch(streamName: String, zoom: CGFloat, centerX: CGFloat, centerY: CGFloat) {
        guard let session, session.isReachable else { return }
        session.sendMessage([
            "action": "showCamera",
            "streamName": streamName,
            "zoom": Double(zoom),
            "centerX": Double(centerX),
            "centerY": Double(centerY)
        ], replyHandler: nil)
    }

    // MARK: - App Lifecycle (Fix #3)

    @objc private nonisolated func appDidEnterBackground() {
        Task { @MainActor in
            self.isAppBackgrounded = true
            log.info("App backgrounded — notifying Watch")
            // Tell Watch the stream is pausing
            if self.watchedStreamName != nil, let session = self.session, session.isReachable {
                session.sendMessage(
                    ["action": "streamPaused", "reason": "background"],
                    replyHandler: nil,
                    errorHandler: { error in log.error("streamPaused send failed: \(error)") }
                )
            }
        }
    }

    @objc private nonisolated func appWillEnterForeground() {
        Task { @MainActor in
            self.isAppBackgrounded = false
            log.info("App foregrounded — resuming Watch stream if needed")
            // Resume streaming if Watch is still subscribed (and still entitled)
            if let name = self.watchedStreamName, self.isWatchUnlocked,
               let session = self.session, session.isReachable {
                session.sendMessage(
                    ["action": "streamResumed"],
                    replyHandler: nil,
                    errorHandler: { error in log.error("streamResumed send failed: \(error)") }
                )
                // Re-subscribe to restart the stream tasks
                let mode = self.currentMode
                let viewport = (self.viewportZoom, self.viewportCenterX, self.viewportCenterY)
                self.subscribeToStream(name, mode: mode, viewport: viewport)
            }
        }
    }

    // MARK: - Stream Management

    private func subscribeToStream(_ streamName: String, mode: WatchStreamMode, viewport: (CGFloat, CGFloat, CGFloat)?) {
        log.info("Watch subscribing to: \(streamName) mode: \(mode.rawValue)")
        lastWatchSubscription = (name: streamName, mode: mode)
        unsubscribeFromStream(clearRecovery: false)

        streamGeneration &+= 1
        watchedStreamName = streamName
        currentMode = mode
        isWatchStreamDegraded = false

        if let (z, cx, cy) = viewport {
            viewportZoom = z
            viewportCenterX = cx
            viewportCenterY = cy
        }

        guard let service = go2rtcService else {
            log.error("No go2rtcService available for Watch streaming")
            return
        }

        if mode != .audioOnly {
            // Start snapshot polling immediately so Watch gets frames fast.
            // Also try MJPEG in parallel — if it succeeds, it'll take over
            // by bumping streamGeneration when we promote it.
            startSnapshotPolling(service: service, streamName: streamName)
            tryUpgradeToMJPEG(service: service, streamName: streamName)
        }
        if mode != .videoOnly {
            startAudioStreaming(service: service, streamName: streamName)
        }
    }

    private func unsubscribeFromStream(clearRecovery: Bool = true) {
        streamGeneration &+= 1
        if clearRecovery { lastWatchSubscription = nil }
        snapshotTask?.cancel()
        snapshotTask = nil
        audioTask?.cancel()
        audioTask = nil
        watchedStreamName = nil
        viewportZoom = 1.0
        viewportCenterX = 0.5
        viewportCenterY = 0.5
        videoSendInFlight = false
        lastCropViewport = nil
        lastCroppedFrame = nil

        // Invalidate URLSessions to prevent leaked connections
        mjpegSession?.invalidateAndCancel()
        mjpegSession = nil
        audioStreamSession?.invalidateAndCancel()
        audioStreamSession = nil
    }

    // MARK: - Viewport Snapshot

    /// Captures current viewport values for use in detached tasks.
    private func snapshotViewport() -> ViewportSnapshot {
        ViewportSnapshot(zoom: viewportZoom, centerX: viewportCenterX, centerY: viewportCenterY)
    }

    // MARK: - Video streaming (old startVideoStreaming removed — now uses polling + MJPEG upgrade)

    /// Tries MJPEG streaming in the background. If it gets a frame, replaces snapshot polling.
    private func tryUpgradeToMJPEG(service: Go2RTCService, streamName: String) {
        let generation = streamGeneration
        Task.detached { [weak self] in
            do {
                let (url, urlSession) = try service.openMJPEGStream(streamName: streamName)

                // Store the session immediately (respecting generation) so a
                // resubscribe/unsubscribe can invalidate it even if connect
                // stalls before the first frame — otherwise it leaks until the
                // request timeout. If the generation already moved on, this open
                // is stale: invalidate now and bail.
                let stored = await MainActor.run { () -> Bool in
                    guard let self, self.streamGeneration == generation else { return false }
                    self.mjpegSession = urlSession
                    return true
                }
                guard stored else {
                    urlSession.invalidateAndCancel()
                    return
                }

                // 10s watchdog. gotFrame is shared across executors (watchdog
                // Task reads, byte-loop writes), so guard it with a lock.
                let gotFrame = AtomicFlag()
                let watchdog = Task {
                    try await Task.sleep(for: .seconds(10))
                    if !gotFrame.isSet { urlSession.invalidateAndCancel() }
                }

                let (bytes, response) = try await urlSession.bytes(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    watchdog.cancel()
                    return
                }

                var buffer = Data()
                let jpegStart = Data([0xFF, 0xD8])
                let jpegEnd = Data([0xFF, 0xD9])
                var inFrame = false

                for try await byte in bytes {
                    if Task.isCancelled { break }
                    guard await MainActor.run(body: { self?.streamGeneration == generation }) else { break }

                    buffer.append(byte)
                    if !inFrame {
                        if buffer.count >= 2 && buffer.suffix(2) == jpegStart {
                            buffer = jpegStart; inFrame = true
                        } else if buffer.count > 256 {
                            buffer.removeAll(keepingCapacity: true)
                        }
                    } else if buffer.count >= 2 && buffer.suffix(2) == jpegEnd {
                        if !gotFrame.set() {
                            watchdog.cancel()
                            // Promote: stop snapshot polling, take over with MJPEG
                            // mjpegSession was already stored right after open.
                            await MainActor.run {
                                self?.snapshotTask?.cancel()
                                self?.snapshotTask = nil
                                self?.isWatchStreamDegraded = false
                            }
                            log.info("MJPEG upgrade succeeded — switching from snapshot polling")
                        }

                        let viewport = await MainActor.run { self?.snapshotViewport() }
                        guard let viewport else { break }

                        let frame: Data
                        if let cached = await MainActor.run(body: { self?.cachedCropIfUnchanged(viewport: viewport, rawSize: buffer.count) }) {
                            frame = cached
                        } else {
                            let cropped = Self.cropFrame(buffer, viewport: viewport)
                            let sized = Self.ensureFrameFits(cropped)
                            await MainActor.run { self?.updateCropCache(viewport: viewport, frame: sized) }
                            frame = sized
                        }

                        let shouldSend = await MainActor.run { () -> Bool in
                            guard let self else { return false }
                            if self.videoSendInFlight { return false }
                            self.videoSendInFlight = true
                            return true
                        }
                        if shouldSend { await self?.sendVideoFrame(frame) }
                        buffer.removeAll(keepingCapacity: true)
                        inFrame = false
                    } else if buffer.count > maxFrameBufferSize {
                        buffer.removeAll(keepingCapacity: true)
                        inFrame = false
                    }
                }
            } catch {
                // MJPEG failed — snapshot polling continues, no action needed.
                // Skip if this generation was already torn down (the throw is
                // then our own invalidateAndCancel on unsubscribe, not a fault).
                if !Task.isCancelled {
                    let stillCurrent = await MainActor.run { self?.streamGeneration == generation }
                    if stillCurrent {
                        log.info("MJPEG upgrade failed (snapshot polling continues): \(error)")
                        await MainActor.run { self?.isWatchStreamDegraded = true }
                    }
                }
            }
        }
    }

    // fallbackToPollingIfStillActive removed — polling starts immediately now

    private func startSnapshotPolling(service: Go2RTCService, streamName: String) {
        let generation = streamGeneration
        snapshotTask = Task {
            while !Task.isCancelled && generation == streamGeneration {
                // Backpressure: wait for previous frame to be delivered
                if !videoSendInFlight {
                    do {
                        let jpegData = try await service.fetchFrame(streamName: streamName)
                        let viewport = snapshotViewport()
                        let cropped = Self.cropFrame(jpegData, viewport: viewport)
                        let sizedFrame = Self.ensureFrameFits(cropped)
                        if sizedFrame.count + 1 <= maxWCMessageSize {
                            videoSendInFlight = true
                            sendVideoFrame(sizedFrame)
                        }
                    } catch {
                        if !Task.isCancelled {
                            log.error("Snapshot fetch failed: \(error)")
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Crop Cache (Fix #9)

    private func cachedCropIfUnchanged(viewport: ViewportSnapshot, rawSize: Int) -> Data? {
        guard let lastVP = lastCropViewport, let lastFrame = lastCroppedFrame else { return nil }
        // Only use cache if viewport is identical (same zoom+pan)
        if abs(lastVP.zoom - viewport.zoom) < 0.001
            && abs(lastVP.centerX - viewport.centerX) < 0.001
            && abs(lastVP.centerY - viewport.centerY) < 0.001 {
            return lastFrame
        }
        return nil
    }

    private func updateCropCache(viewport: ViewportSnapshot, frame: Data) {
        lastCropViewport = viewport
        lastCroppedFrame = frame
    }

    // MARK: - Frame Size Gate (nonisolated — Fix #1)

    /// Re-encodes at progressively lower quality until the frame fits under the WCSession limit.
    private nonisolated static func ensureFrameFits(_ jpegData: Data) -> Data {
        guard jpegData.count > maxWCMessageSize else { return jpegData }

        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return jpegData
        }

        let uiImage = UIImage(cgImage: cgImage)
        for quality in [0.4, 0.25, 0.15, 0.08] as [CGFloat] {
            if let reencoded = uiImage.jpegData(compressionQuality: quality),
               reencoded.count <= maxWCMessageSize {
                return reencoded
            }
        }

        // Last resort: scale down progressively until it fits
        for targetWidth in [480.0, 320.0, 240.0] as [CGFloat] {
            let ratio = targetWidth / CGFloat(cgImage.width)
            if ratio >= 1 { continue }
            let newSize = CGSize(width: targetWidth, height: CGFloat(cgImage.height) * ratio)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let scaled = renderer.image { _ in uiImage.draw(in: CGRect(origin: .zero, size: newSize)) }
            if let data = scaled.jpegData(compressionQuality: 0.3), data.count <= maxWCMessageSize {
                return data
            }
        }
        return jpegData
    }

    // MARK: - Viewport Cropping (nonisolated — Fix #1)

    /// Crops a JPEG frame to the given viewport. Runs off MainActor.
    private nonisolated static func cropFrame(_ jpegData: Data, viewport: ViewportSnapshot) -> Data {
        guard viewport.isCropping else { return jpegData }

        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return jpegData
        }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let cropW = imgW / viewport.zoom
        let cropH = imgH / viewport.zoom
        let cropX = (viewport.centerX * imgW) - (cropW / 2)
        let cropY = (viewport.centerY * imgH) - (cropH / 2)
        let clampedX = min(max(cropX, 0), imgW - cropW)
        let clampedY = min(max(cropY, 0), imgH - cropH)
        let cropRect = CGRect(x: clampedX, y: clampedY, width: cropW, height: cropH)

        guard let cropped = cgImage.cropping(to: cropRect) else {
            return jpegData
        }

        let uiImage = UIImage(cgImage: cropped)
        return uiImage.jpegData(compressionQuality: 0.6) ?? jpegData
    }

    // MARK: - Audio: Stream /api/stream.mp3 (MP3 frame-aligned chunking)

    private func startAudioStreaming(service: Go2RTCService, streamName: String) {
        audioTask = Task.detached { [weak self] in
            do {
                let (url, streamSession) = try service.openAudioStream(streamName: streamName)
                await MainActor.run { self?.audioStreamSession = streamSession }

                // Watchdog: cancel if no data in 10s. receivedAnyData is shared
                // across executors (watchdog reads, byte-loop writes), so guard
                // it with a lock.
                let receivedAnyData = AtomicFlag()
                let watchdog = Task {
                    try await Task.sleep(for: .seconds(10))
                    if !receivedAnyData.isSet {
                        log.warning("Audio stream watchdog: no data in 10s, cancelling")
                        streamSession.invalidateAndCancel()
                    }
                }

                let (bytes, response) = try await streamSession.bytes(from: url)

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    log.error("Audio stream returned HTTP \(httpResponse.statusCode)")
                    watchdog.cancel()
                    return
                }

                var buffer = Data()

                for try await byte in bytes {
                    if Task.isCancelled { break }
                    if !receivedAnyData.set() {
                        watchdog.cancel()
                        log.info("Audio stream first data received")
                    }
                    buffer.append(byte)

                    // Accumulate until we have enough data, then split on MP3 frame boundaries
                    if buffer.count >= 4096 {
                        let splitPoint = Self.findLastMP3FrameBoundary(in: buffer)
                        let chunk: Data
                        if splitPoint > 0 {
                            chunk = buffer.prefix(splitPoint)
                            buffer = Data(buffer.suffix(from: splitPoint))
                        } else {
                            chunk = buffer
                            buffer = Data()
                        }
                        await self?.sendTaggedData(tag: .audioChunk, payload: chunk)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    log.error("Audio stream failed: \(error)")
                }
            }
        }
    }

    /// Finds the last MP3 sync word (0xFF 0xE0+) boundary in the buffer.
    private nonisolated static func findLastMP3FrameBoundary(in data: Data) -> Int {
        guard data.count > 2 else { return 0 }
        for i in stride(from: data.count - 2, through: 1, by: -1) {
            if data[data.startIndex + i] == 0xFF && (data[data.startIndex + i + 1] & 0xE0) == 0xE0 {
                return i
            }
        }
        return 0
    }

    // MARK: - Send to Watch

    /// Sends a video frame with backpressure tracking.
    private func sendVideoFrame(_ payload: Data) {
        guard WCSession.default.isReachable else {
            videoSendInFlight = false
            return
        }
        guard payload.count + 1 <= maxWCMessageSize else {
            log.warning("Video frame too large after compression (\(payload.count) bytes), dropping")
            videoSendInFlight = false
            return
        }
        var message = Data(capacity: 1 + payload.count)
        message.append(WatchDataTag.videoFrame.rawValue)
        message.append(payload)
        // Tie the in-flight reset to actual delivery: the Watch's reply (acked
        // receipt) or the error callback is the real completion signal, not a
        // guessed timer. Exactly one of the two fires per send, so it's a single
        // owner of the flag and the relay can't latch true at teardown.
        WCSession.default.sendMessageData(
            message,
            replyHandler: { [weak self] _ in
                Task { @MainActor in self?.videoSendInFlight = false }
            },
            errorHandler: { [weak self] error in
                log.error("Video send failed: \(error)")
                Task { @MainActor in self?.videoSendInFlight = false }
            }
        )
    }

    private func sendTaggedData(tag: WatchDataTag, payload: Data) {
        guard WCSession.default.isReachable else { return }
        guard payload.count + 1 <= maxWCMessageSize else {
            log.warning("Audio chunk too large (\(payload.count) bytes), dropping")
            return
        }
        var message = Data(capacity: 1 + payload.count)
        message.append(tag.rawValue)
        message.append(payload)
        WCSession.default.sendMessageData(message, replyHandler: nil, errorHandler: { error in
            log.error("sendMessageData failed: \(error)")
        })
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
                // Don't clear recovery info — we may need to re-subscribe on BT restore
                self.unsubscribeFromStream(clearRecovery: false)
            } else if let sub = self.lastWatchSubscription, self.watchedStreamName == nil {
                // BT blip recovery: Watch had an active subscription before the blip.
                // Check wrist behavior — only auto-recover for non-eco modes.
                let behavior = UserDefaults.standard.string(forKey: "wristBehavior") ?? "eco"
                if behavior != "eco" && self.isWatchUnlocked {
                    log.info("BT recovered — restoring stream \(sub.name) mode \(sub.mode.rawValue)")
                    self.subscribeToStream(sub.name, mode: sub.mode, viewport: nil)
                } else {
                    self.lastWatchSubscription = nil
                }
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleMessage(message, replyHandler: nil)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleMessage(message, replyHandler: replyHandler)
    }

    private nonisolated func handleMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?
    ) {
        guard let request = message["request"] as? String else {
            replyHandler?([:])
            return
        }
        Task { @MainActor in
            switch request {
            case "subscribe":
                // Hard lock: no Watch unlock purchase means no streaming. Reply
                // "locked" so the Watch exits its spinner and shows the paywall.
                guard self.isWatchUnlocked else {
                    log.info("Rejecting subscribe — Watch not unlocked")
                    replyHandler?(["status": "locked"])
                    return
                }
                if let name = message["streamName"] as? String {
                    // Reject stale/reordered subscribe messages using monotonic generation counter
                    if let gen = message["generation"] as? UInt64 {
                        guard gen >= self.lastWatchGeneration else {
                            log.info("Ignoring stale subscribe (gen \(gen) < \(self.lastWatchGeneration))")
                            replyHandler?(["status": "stale"])
                            return
                        }
                        self.lastWatchGeneration = gen
                    }
                    let modeStr = message["mode"] as? String ?? "videoAndAudio"
                    let mode = WatchStreamMode(rawValue: modeStr) ?? .videoAndAudio
                    var viewport: (CGFloat, CGFloat, CGFloat)?
                    if let z = message["zoom"] as? Double {
                        let cx = message["centerX"] as? Double ?? 0.5
                        let cy = message["centerY"] as? Double ?? 0.5
                        viewport = (CGFloat(z), CGFloat(cx), CGFloat(cy))
                    }
                    self.subscribeToStream(name, mode: mode, viewport: viewport)
                }
            case "unsubscribe":
                self.unsubscribeFromStream(clearRecovery: true)
            case "viewport":
                let zoom = message["zoom"] as? Double ?? 1.0
                let cx = message["centerX"] as? Double ?? 0.5
                let cy = message["centerY"] as? Double ?? 0.5
                self.viewportZoom = zoom
                self.viewportCenterX = cx
                self.viewportCenterY = cy
                // Invalidate crop cache when viewport changes
                self.lastCropViewport = nil
                self.lastCroppedFrame = nil
            case "getStreams":
                replyHandler?(["streams": self.availableStreamNames, "selectedStreams": self.selectedStreamEntries])
                return
            case "setWristBehavior":
                if let value = message["value"] as? String {
                    UserDefaults.standard.set(value, forKey: "wristBehavior")
                    NotificationCenter.default.post(name: .wristBehaviorChangedFromWatch, object: value)
                }
            case "setWatchSettings":
                if let v = message["glanceModeEnabled"] as? Bool { UserDefaults.standard.set(v, forKey: "watchGlanceModeEnabled") }
                if let v = message["defaultStreamMode"] as? String { UserDefaults.standard.set(v, forKey: "watchDefaultStreamMode") }
                if let v = message["streamTimeoutMinutes"] as? Int { UserDefaults.standard.set(v, forKey: "watchStreamTimeoutMinutes") }
                if let v = message["glanceDefaultCamera"] as? String { UserDefaults.standard.set(v, forKey: "watchGlanceDefaultCamera") }
                NotificationCenter.default.post(name: .watchSettingsChangedFromWatch, object: nil)
            default:
                break
            }
            replyHandler?(["status": "ok"])
        }
    }
}
