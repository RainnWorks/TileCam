import WebRTC
import UIKit

/// Captures periodic snapshots from an RTCVideoTrack and delivers JPEG data.
/// Called from WebRTC's rendering thread — the onSnapshot callback is thread-safe.
final class SnapshotRenderer: NSObject, RTCVideoRenderer {
    private let targetWidth: CGFloat
    private let compressionQuality: CGFloat
    private let minInterval: TimeInterval
    private var lastCapture: CFTimeInterval = 0
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    var onSnapshot: (@Sendable (Data) -> Void)?

    init(targetWidth: CGFloat = 200, compressionQuality: CGFloat = 0.4, fps: Double = 2) {
        self.targetWidth = targetWidth
        self.compressionQuality = compressionQuality
        self.minInterval = 1.0 / fps
        super.init()
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let onSnapshot else { return }
        let now = CACurrentMediaTime()
        guard now - lastCapture >= minInterval else { return }
        lastCapture = now

        guard let buffer = frame.buffer as? RTCCVPixelBuffer else { return }
        let ciImage = CIImage(cvPixelBuffer: buffer.pixelBuffer)

        let scale = targetWidth / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: compressionQuality) else { return }

        onSnapshot(data)
    }
}
