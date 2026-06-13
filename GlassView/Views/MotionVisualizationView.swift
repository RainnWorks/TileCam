import CoreImage
import SwiftUI
import UIKit
import WebRTC

struct MotionVisualizationView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack
    let mode: MotionVisualizationMode
    var viewport: MotionViewport = MotionViewport()

    func makeUIView(context: Context) -> MotionRenderView {
        let view = MotionRenderView()
        view.configure(track: videoTrack, mode: mode)
        view.viewport = viewport
        return view
    }

    func updateUIView(_ view: MotionRenderView, context: Context) {
        view.viewport = viewport
        if view.currentMode != mode {
            view.updateMode(mode)
        }
        if view.currentTrack !== videoTrack {
            view.configure(track: videoTrack, mode: mode)
        }
    }

    static func dismantleUIView(_ view: MotionRenderView, coordinator: ()) {
        view.tearDown()
    }
}

final class MotionRenderView: UIView {
    private(set) var currentMode: MotionVisualizationMode = .off
    private(set) weak var currentTrack: RTCVideoTrack?
    var viewport = MotionViewport()

    private let frameSink = VideoFrameSink()
    private var displayLink: CADisplayLink?
    private var analyzer: MotionAnalyzer?
    private let imageView = UIImageView()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(track: RTCVideoTrack, mode: MotionVisualizationMode) {
        tearDown()
        currentTrack = track
        track.add(frameSink)
        updateMode(mode)
        startDisplayLink()
    }

    func updateMode(_ mode: MotionVisualizationMode) {
        currentMode = mode
        analyzer?.reset()
        analyzer = makeAnalyzer(for: mode)
        if mode == .off {
            imageView.image = nil
        }
    }

    func tearDown() {
        stopDisplayLink()
        currentTrack?.remove(frameSink)
        currentTrack = nil
        analyzer = nil
        imageView.image = nil
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let buffer = frameSink.latestPixelBuffer, let analyzer else { return }
        analyzer.feed(pixelBuffer: buffer, timestamp: CACurrentMediaTime(), viewport: viewport)
        guard let output = analyzer.outputImage else { return }

        let renderBounds = output.extent
        guard let cgImage = ciContext.createCGImage(output, from: renderBounds, format: .RGBA8, colorSpace: colorSpace) else { return }
        imageView.image = UIImage(cgImage: cgImage)
    }
}
