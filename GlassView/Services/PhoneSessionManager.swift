import Foundation
import WatchConnectivity
import UIKit
import os

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

/// Manages WatchConnectivity on the iPhone side.
/// Streams JPEG snapshots and MP3 audio from go2rtc HTTP endpoints to the Watch.
/// The Watch controls its own viewport; iPhone just crops frames to match.
@MainActor
final class PhoneSessionManager: NSObject, ObservableObject {
    static let shared = PhoneSessionManager()

    @Published var isWatchReachable = false

    private var session: WCSession?
    private var go2rtcService: Go2RTCService?

    private var watchedStreamName: String?
    private var currentMode: WatchStreamMode = .videoAndAudio
    private var snapshotTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?

    /// Current viewport from Watch, used for cropping MJPEG frames.
    private var viewportZoom: CGFloat = 1.0
    private var viewportCenterX: CGFloat = 0.5
    private var viewportCenterY: CGFloat = 0.5

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

    // MARK: - Stream Management

    private func subscribeToStream(_ streamName: String, mode: WatchStreamMode, viewport: (CGFloat, CGFloat, CGFloat)?) {
        log.info("Watch subscribing to: \(streamName) mode: \(mode.rawValue)")
        unsubscribeFromStream()
        watchedStreamName = streamName
        currentMode = mode

        // Apply initial viewport if provided
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
            startVideoStreaming(service: service, streamName: streamName)
        }
        if mode != .videoOnly {
            startAudioStreaming(service: service, streamName: streamName)
        }
    }

    private func unsubscribeFromStream() {
        snapshotTask?.cancel()
        snapshotTask = nil
        audioTask?.cancel()
        audioTask = nil
        watchedStreamName = nil
        viewportZoom = 1.0
        viewportCenterX = 0.5
        viewportCenterY = 0.5
    }

    // MARK: - Video: MJPEG stream from /api/stream.mjpeg

    private func startVideoStreaming(service: Go2RTCService, streamName: String) {
        snapshotTask = Task.detached { [weak self] in
            do {
                let (url, session) = try service.openMJPEGStream(streamName: streamName)
                let (bytes, _) = try await session.bytes(from: url)

                var buffer = Data()
                let jpegStart = Data([0xFF, 0xD8])
                let jpegEnd = Data([0xFF, 0xD9])
                var inFrame = false

                for try await byte in bytes {
                    if Task.isCancelled { break }
                    buffer.append(byte)

                    if !inFrame {
                        if buffer.count >= 2 && buffer.suffix(2) == jpegStart {
                            buffer = jpegStart
                            inFrame = true
                        } else if buffer.count > 256 {
                            buffer.removeAll(keepingCapacity: true)
                        }
                    } else {
                        if buffer.count >= 2 && buffer.suffix(2) == jpegEnd {
                            let frame = await self?.cropFrameToViewport(buffer) ?? buffer
                            await self?.sendTaggedData(tag: .videoFrame, payload: frame)
                            buffer.removeAll(keepingCapacity: true)
                            inFrame = false
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    log.error("MJPEG stream failed: \(error)")
                    await self?.startSnapshotPolling(service: service, streamName: streamName)
                }
            }
        }
    }

    private func startSnapshotPolling(service: Go2RTCService, streamName: String) {
        snapshotTask = Task {
            while !Task.isCancelled {
                do {
                    var jpegData = try await service.fetchFrame(streamName: streamName)
                    jpegData = cropFrameToViewport(jpegData)
                    sendTaggedData(tag: .videoFrame, payload: jpegData)
                } catch {
                    if !Task.isCancelled {
                        log.error("Snapshot fetch failed: \(error)")
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Viewport Cropping

    private func cropFrameToViewport(_ jpegData: Data) -> Data {
        guard viewportZoom > 1.01 else { return jpegData }

        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return jpegData
        }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let cropW = imgW / viewportZoom
        let cropH = imgH / viewportZoom
        let cropX = (viewportCenterX * imgW) - (cropW / 2)
        let cropY = (viewportCenterY * imgH) - (cropH / 2)
        let clampedX = min(max(cropX, 0), imgW - cropW)
        let clampedY = min(max(cropY, 0), imgH - cropH)
        let cropRect = CGRect(x: clampedX, y: clampedY, width: cropW, height: cropH)

        guard let cropped = cgImage.cropping(to: cropRect) else {
            return jpegData
        }

        let uiImage = UIImage(cgImage: cropped)
        return uiImage.jpegData(compressionQuality: 0.6) ?? jpegData
    }

    // MARK: - Audio: Stream /api/stream.mp3

    private func startAudioStreaming(service: Go2RTCService, streamName: String) {
        audioTask = Task.detached { [weak self] in
            do {
                let (url, streamSession) = try service.openAudioStream(streamName: streamName)
                let (bytes, _) = try await streamSession.bytes(from: url)

                var buffer = Data()
                let chunkSize = 4096

                for try await byte in bytes {
                    if Task.isCancelled { break }
                    buffer.append(byte)
                    if buffer.count >= chunkSize {
                        await self?.sendTaggedData(tag: .audioChunk, payload: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    log.error("Audio stream failed: \(error)")
                }
            }
        }
    }

    // MARK: - Send to Watch

    private func sendTaggedData(tag: WatchDataTag, payload: Data) {
        guard WCSession.default.isReachable else { return }
        var message = Data(capacity: 1 + payload.count)
        message.append(tag.rawValue)
        message.append(payload)
        WCSession.default.sendMessageData(message, replyHandler: nil, errorHandler: nil)
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
                if let name = message["streamName"] as? String {
                    let modeStr = message["mode"] as? String ?? "videoAndAudio"
                    let mode = WatchStreamMode(rawValue: modeStr) ?? .videoAndAudio
                    // Watch may include initial viewport from "showCamera"
                    var viewport: (CGFloat, CGFloat, CGFloat)?
                    if let z = message["zoom"] as? Double {
                        let cx = message["centerX"] as? Double ?? 0.5
                        let cy = message["centerY"] as? Double ?? 0.5
                        viewport = (z, cx, cy)
                    }
                    self.subscribeToStream(name, mode: mode, viewport: viewport)
                }
            case "unsubscribe":
                self.unsubscribeFromStream()
            case "viewport":
                // Watch-originated viewport update (for cropping only)
                let zoom = message["zoom"] as? Double ?? 1.0
                let cx = message["centerX"] as? Double ?? 0.5
                let cy = message["centerY"] as? Double ?? 0.5
                self.viewportZoom = zoom
                self.viewportCenterX = cx
                self.viewportCenterY = cy
            default:
                break
            }
            replyHandler?(["status": "ok"])
        }
    }
}
