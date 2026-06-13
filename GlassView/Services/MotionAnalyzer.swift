import CoreImage
import CoreVideo

enum MotionVisualizationMode: String, CaseIterable, Identifiable {
    case off
    case eulerian
    case opticalFlow
    case heatmap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .eulerian: "Breathing"
        case .opticalFlow: "Motion Flow"
        case .heatmap: "Heat Map"
        }
    }

    var icon: String {
        switch self {
        case .off: "eye.slash"
        case .eulerian: "waveform.path"
        case .opticalFlow: "wind"
        case .heatmap: "flame"
        }
    }

    var next: MotionVisualizationMode {
        let all = Self.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }
}

/// Normalized viewport matching the user's zoom/pan.
struct MotionViewport {
    var zoom: CGFloat = 1
    var centerX: CGFloat = 0.5
    var centerY: CGFloat = 0.5

    /// Crops a CIImage to the visible region. Returns the cropped image
    /// whose extent origin reflects its position in the full frame.
    func crop(_ image: CIImage) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height
        guard zoom > 1.01 else { return image }
        let cropW = w / zoom
        let cropH = h / zoom
        let cropX = (centerX * w - cropW / 2).clamped(0, w - cropW)
        let cropY = ((1 - centerY) * h - cropH / 2).clamped(0, h - cropH)
        return image.cropped(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
    }
}

protocol MotionAnalyzer: AnyObject {
    var isReady: Bool { get }
    func feed(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, viewport: MotionViewport)
    var outputImage: CIImage? { get }
    func reset()
}

func makeAnalyzer(for mode: MotionVisualizationMode) -> MotionAnalyzer? {
    switch mode {
    case .off: nil
    case .eulerian: EulerianMagnifier()
    case .opticalFlow: MotionFlowAnalyzer()
    case .heatmap: IntensityHeatmapAnalyzer()
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lo), hi)
    }
}
