import AVKit
import CoreImage
import CoreMedia
import CoreVideo
import UIKit
import WebRTC
import os

private let log = Logger(subsystem: "works.rainn.tilecam", category: "PiP")

// MARK: - Frame Sink

/// Captures the latest CVPixelBuffer from an RTCVideoTrack.
/// `renderFrame` runs on WebRTC's decoder thread while `latestPixelBuffer` is
/// read on the main thread, so the buffer is guarded by an internal lock —
/// the justification for `@unchecked Sendable`.
final class VideoFrameSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private var _latestPixelBuffer: CVPixelBuffer?
    private var bufferLock = os_unfair_lock()
    private(set) var frameSize: CGSize = .zero

    /// Thread-safe snapshot of the latest decoded buffer.
    var latestPixelBuffer: CVPixelBuffer? {
        os_unfair_lock_lock(&bufferLock)
        defer { os_unfair_lock_unlock(&bufferLock) }
        return _latestPixelBuffer
    }

    func setSize(_ size: CGSize) {
        frameSize = size
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        if let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            os_unfair_lock_lock(&bufferLock)
            _latestPixelBuffer = cvBuffer.pixelBuffer
            os_unfair_lock_unlock(&bufferLock)
        }
    }
}

// MARK: - Stream Snapshot

struct PiPStreamEntry {
    let name: String
    let sink: VideoFrameSink
    weak var track: RTCVideoTrack?
    /// Zoom level (1 = full view)
    var zoom: CGFloat = 1
    /// Normalized center of visible region (0..1 in source image coords)
    var centerX: CGFloat = 0.5
    var centerY: CGFloat = 0.5
}

// MARK: - Display View

/// A hidden view backed by an `AVSampleBufferDisplayLayer`. Added to the app
/// window so PiP has a live layer to promote into its floating window.
final class PiPDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - PiP Manager

@MainActor
final class PiPManager: NSObject, ObservableObject {
    static let shared = PiPManager()

    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    /// Set when user explicitly closes PiP via X button. Prevents auto-restart until streams change.
    @Published var userDismissed = false

    var onUserClose: (() -> Void)?

    private var restoringToApp = false
    private var pipController: AVPictureInPictureController?
    private var displayView: PiPDisplayView?
    private var pixelBufferPool: CVPixelBufferPool?
    private var renderTimer: CADisplayLink?
    private var entries: [PiPStreamEntry] = []
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private let outputWidth = 640
    private let outputHeight = 360

    private override init() {
        super.init()
        isPossible = AVPictureInPictureController.isPictureInPictureSupported()
    }

    // MARK: - Public API

    /// Sets up PiP infrastructure while in foreground. iOS will auto-start PiP on background.
    /// viewport dict: streamName → (zoom, centerX, centerY)
    func prepare(clients: [WebRTCClient], viewports: [String: (CGFloat, CGFloat, CGFloat)]) {
        guard isPossible else { return }
        userDismissed = false

        tearDownSinks()

        // Set up sinks on video tracks
        for client in clients {
            guard let track = client.videoTrack else { continue }
            let sink = VideoFrameSink()
            track.add(sink)
            let vp = viewports[client.streamName] ?? (1, 0.5, 0.5)
            log.info("PiP entry \(client.streamName): zoom=\(vp.0) center=(\(vp.1), \(vp.2))")
            entries.append(PiPStreamEntry(
                name: client.streamName,
                sink: sink,
                track: track,
                zoom: vp.0,
                centerX: vp.1,
                centerY: vp.2
            ))
        }

        guard !entries.isEmpty else {
            log.warning("No video tracks for PiP")
            return
        }

        // Create the display view in the window. Sized to match the window
        // and inserted behind everything else so it's fully obscured by the
        // app UI — but gives PiP a full-screen source rect, so the restore
        // animation scales cleanly into the app instead of shooting to a
        // tiny top-left corner.
        if displayView == nil,
           let window = UIApplication.shared.connectedScenes
               .compactMap({ $0 as? UIWindowScene })
               .first?.keyWindow {
            let dv = PiPDisplayView(frame: window.bounds)
            dv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.insertSubview(dv, at: 0)
            displayView = dv
        }

        // Lazily create the pixel buffer pool for composited frames.
        if pixelBufferPool == nil {
            pixelBufferPool = makePixelBufferPool(width: outputWidth, height: outputHeight)
        }

        // Create PiP controller using sample-buffer content source. This mode
        // provides the stock tap-to-reveal/auto-hide chrome with play/pause,
        // close, and restore buttons — which is what we want.
        if pipController == nil, let layer = displayView?.displayLayer {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: layer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.requiresLinearPlayback = true
            pipController = controller
            log.info("PiP controller created (sample buffer mode)")
        }

        // Kick the render loop immediately so the display layer has content
        // by the time iOS promotes it into the PiP window.
        startRenderLoop()
        // Push a synchronous first frame so the layer isn't empty when PiP
        // animates in.
        renderTick()

        isActive = true
        log.info("PiP prepared with \(self.entries.count) streams")
    }

    /// Pause rendering when returning to foreground. Keeps controller alive for next background.
    func pause() {
        stopRenderLoop()
        pipController?.stopPictureInPicture()
        // Rendering and PiP are stopped, so the flag must reflect "not active".
        // Leaving it stale-true causes the .background handler to skip
        // suspendLiveMedia() and drain battery. A legitimate auto-PiP float
        // still works: .inactive→prepare() re-sets isActive before .background.
        isActive = false
    }

    /// Full teardown — call when streams are removed or user explicitly closes PiP.
    func stop() {
        stopRenderLoop()

        pipController?.stopPictureInPicture()
        pipController = nil

        tearDownSinks()

        displayView?.displayLayer.flushAndRemoveImage()
        displayView?.removeFromSuperview()
        displayView = nil
        pixelBufferPool = nil

        isActive = false
    }

    func updateViewport(streamName: String, zoom: CGFloat, centerX: CGFloat, centerY: CGFloat) {
        guard let idx = entries.firstIndex(where: { $0.name == streamName }) else { return }
        entries[idx].zoom = zoom
        entries[idx].centerX = centerX
        entries[idx].centerY = centerY
    }

    private func tearDownSinks() {
        for entry in entries {
            entry.track?.remove(entry.sink)
        }
        entries.removeAll()
    }

    // MARK: - Render Loop

    private func startRenderLoop() {
        guard renderTimer == nil else { return }
        let timer = CADisplayLink(target: self, selector: #selector(renderTick))
        timer.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 15)
        timer.add(to: .main, forMode: .common)
        renderTimer = timer
        for entry in entries {
            log.info("Render start — \(entry.name): zoom=\(entry.zoom) center=(\(entry.centerX),\(entry.centerY))")
        }
        log.info("Render loop started")
    }

    private func stopRenderLoop() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    @objc private func renderTick() {
        guard let displayLayer = displayView?.displayLayer, !entries.isEmpty else { return }

        if displayLayer.status == .failed {
            log.error("Display layer failed — flushing and continuing")
            displayLayer.flush()
        }

        guard let ciImage = compositeFrames() else { return }
        guard let sampleBuffer = makeSampleBuffer(from: ciImage) else { return }
        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - Sample Buffer Bridge

    private func makePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        if status != kCVReturnSuccess {
            log.error("CVPixelBufferPoolCreate failed: \(status)")
            return nil
        }
        return pool
    }

    private func makeSampleBuffer(from ciImage: CIImage) -> CMSampleBuffer? {
        guard let pool = pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard poolStatus == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        ciContext.render(ciImage, to: pb, bounds: ciImage.extent, colorSpace: colorSpace)

        var formatDesc: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &formatDesc
        )
        guard fmtStatus == noErr, let desc = formatDesc else { return nil }

        let pts = CMTime(value: Int64(CACurrentMediaTime() * 1_000_000), timescale: 1_000_000)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return nil }

        // Mark for immediate display so the layer doesn't buffer for live content.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sb
    }

    // MARK: - Compositing

    private func compositeFrames() -> CIImage? {
        let count = entries.count
        guard count > 0 else { return nil }

        let hasAnyFrame = entries.contains { $0.sink.latestPixelBuffer != nil }
        guard hasAnyFrame else { return nil }

        let w = CGFloat(outputWidth)
        let h = CGFloat(outputHeight)

        let columns = gridColumns(for: count)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let tileW = w / CGFloat(columns)
        let tileH = h / CGFloat(rows)

        var compositedImage = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))

        for (index, entry) in entries.enumerated() {
            guard let pixelBuffer = entry.sink.latestPixelBuffer else { continue }

            let col = index % columns
            let row = index / columns

            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            let sourceW = sourceImage.extent.width
            let sourceH = sourceImage.extent.height
            guard sourceW > 0, sourceH > 0 else { continue }

            // How many items in this row? (last row may have fewer)
            let itemsInRow = Swift.min(columns, count - row * columns)
            let rowOffset = (w - CGFloat(itemsInRow) * tileW) / 2

            // Tile position in output (CIImage Y-up: row 0 is at top)
            let tileX = CGFloat(col) * tileW + rowOffset
            let tileY = CGFloat(rows - 1 - row) * tileH

            let zoom = Swift.max(entry.zoom, 1.0)

            // Compute visible crop in source pixel coordinates.
            // Start with the zoom-determined crop, then expand to fill the tile aspect ratio.
            let tileAspect = tileW / tileH

            // Base crop from zoom level
            var cropW = sourceW / zoom
            var cropH = sourceH / zoom

            // Expand crop to match tile aspect ratio (aspect-fill: no black bars)
            let cropAspect = cropW / cropH
            if cropAspect < tileAspect {
                // Crop is too tall — widen it
                cropW = cropH * tileAspect
            } else {
                // Crop is too wide — heighten it
                cropH = cropW / tileAspect
            }

            // Clamp to source bounds while preserving aspect ratio. Shrinking
            // one dimension requires shrinking the other proportionally,
            // otherwise scaleX and scaleY diverge and the tile ends up skewed.
            if cropW > sourceW {
                let factor = sourceW / cropW
                cropW = sourceW
                cropH *= factor
            }
            if cropH > sourceH {
                let factor = sourceH / cropH
                cropH = sourceH
                cropW *= factor
            }

            // CIImage Y is flipped vs normalized (0=top in UI, but 0=bottom in CIImage)
            let cropX = (entry.centerX * sourceW - cropW / 2).clamped(0, sourceW - cropW)
            let cropY = ((1 - entry.centerY) * sourceH - cropH / 2).clamped(0, sourceH - cropH)

            let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
            let cropped = sourceImage.cropped(to: cropRect)

            // Scale crop to exactly fill tile
            let scaleX = tileW / cropW
            let scaleY = tileH / cropH
            let offsetX = tileX - cropRect.origin.x * scaleX
            let offsetY = tileY - cropRect.origin.y * scaleY

            let transformed = cropped
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

            // Clip to tile bounds (rounding safety)
            let tileBounds = CGRect(x: tileX, y: tileY, width: tileW, height: tileH)
            let clipped = transformed.cropped(to: tileBounds)

            compositedImage = clipped.composited(over: compositedImage)
        }

        return compositedImage.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func gridColumns(for count: Int) -> Int {
        switch count {
        case 0, 1: return 1
        case 2: return 2
        case 3, 4: return 2
        case 5, 6: return 3
        case 7...9: return 3
        default: return 4
        }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        log.info("PiP will start")
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        log.info("PiP did start")
        Task { @MainActor in
            self.startRenderLoop()
            // Force a frame immediately so the newly promoted PiP window
            // isn't blank while it waits for the next CADisplayLink tick.
            self.renderTick()
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        log.info("PiP restoring to app")
        Task { @MainActor in
            self.restoringToApp = true
        }
        completionHandler(true)
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        log.info("PiP did stop")
        Task { @MainActor in
            self.stopRenderLoop()
            let wasRestoring = self.restoringToApp
            self.restoringToApp = false
            if !wasRestoring {
                self.stop()
                self.onUserClose?()
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        log.error("PiP failed to start: \(error)")
        Task { @MainActor in
            self.isActive = false
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // Live stream — no pause semantics. Ignore.
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Live: infinite range hides the scrubber.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // no-op
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - Helpers

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lo), hi)
    }
}
