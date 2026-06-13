import Accelerate
import CoreImage
import CoreVideo

/// Visualizes motion intensity as a heat-colored overlay.
/// Only areas with detected movement are colored — camera shows through everywhere else.
final class IntensityHeatmapAnalyzer: MotionAnalyzer {
    private(set) var isReady = false
    private(set) var outputImage: CIImage?

    private let processWidth = 160
    private let processHeight = 90
    private let decayAlpha: Float = 0.1
    private let sensitivity: Float = 4.0
    private let noiseFloor: Float = 0.006

    private var previousLuma: [Float]?
    private var heatAccumulator: [Float]?
    private var outputBuffer: CVPixelBuffer?
    private var downsampleBuffer: CVPixelBuffer?
    private let ciContext: CIContext

    init() {
        ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        outputBuffer = EulerianMagnifier.makeBuffer(width: processWidth, height: processHeight)
        downsampleBuffer = EulerianMagnifier.makeBuffer(width: processWidth, height: processHeight)
    }

    func reset() {
        previousLuma = nil
        heatAccumulator = nil
        isReady = false
        outputImage = nil
    }

    func feed(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, viewport: MotionViewport) {
        let fullImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cropped = viewport.crop(fullImage)
        let cropExtent = cropped.extent
        guard cropExtent.width > 0, cropExtent.height > 0, let outBuf = outputBuffer else { return }

        let rgb = downsampleToRGB(cropped)
        let pixelCount = processWidth * processHeight
        guard rgb.count == pixelCount * 3 else { return }

        var luma = [Float](repeating: 0, count: pixelCount)
        let n = vDSP_Length(pixelCount)
        var rW: Float = 0.299, gW: Float = 0.587, bW: Float = 0.114
        vDSP_vsmul(rgb, 1, &rW, &luma, 1, n)
        var gContrib = [Float](repeating: 0, count: pixelCount)
        vDSP_vsmul([Float](rgb[pixelCount..<pixelCount * 2]), 1, &gW, &gContrib, 1, n)
        vDSP_vadd(luma, 1, gContrib, 1, &luma, 1, n)
        var bContrib = [Float](repeating: 0, count: pixelCount)
        vDSP_vsmul([Float](rgb[pixelCount * 2..<pixelCount * 3]), 1, &bW, &bContrib, 1, n)
        vDSP_vadd(luma, 1, bContrib, 1, &luma, 1, n)

        guard let prev = previousLuma else {
            previousLuma = luma
            heatAccumulator = [Float](repeating: 0, count: pixelCount)
            return
        }

        var absDiff = [Float](repeating: 0, count: pixelCount)
        vDSP_vsub(prev, 1, luma, 1, &absDiff, 1, n)
        vDSP_vabs(absDiff, 1, &absDiff, 1, n)

        var threshold = noiseFloor
        vDSP_vthr(absDiff, 1, &threshold, &absDiff, 1, n)

        var alpha = decayAlpha
        var delta = [Float](repeating: 0, count: pixelCount)
        vDSP_vsub(heatAccumulator!, 1, absDiff, 1, &delta, 1, n)
        vDSP_vsma(delta, 1, &alpha, heatAccumulator!, 1, &heatAccumulator!, 1, n)

        previousLuma = luma

        CVPixelBufferLockBaseAddress(outBuf, [])
        let base = CVPixelBufferGetBaseAddress(outBuf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(outBuf)
        for y in 0..<processHeight {
            let row = y * bpr
            for x in 0..<processWidth {
                let i = y * processWidth + x
                let t = min(heatAccumulator![i] * sensitivity, 1.0)
                let off = row + x * 4
                guard t > 0.02 else {
                    base[off] = 0; base[off + 1] = 0; base[off + 2] = 0; base[off + 3] = 0
                    continue
                }
                let a = UInt8(t * 140)
                let (r, g, b) = heatColor(t)
                base[off] = UInt8(Float(b) * t)
                base[off + 1] = UInt8(Float(g) * t)
                base[off + 2] = UInt8(Float(r) * t)
                base[off + 3] = a
            }
        }
        CVPixelBufferUnlockBaseAddress(outBuf, [])

        let pw = CGFloat(processWidth), ph = CGFloat(processHeight)
        let overlay = CIImage(cvPixelBuffer: outBuf)
            .transformed(by: CGAffineTransform(
                scaleX: cropExtent.width / pw,
                y: cropExtent.height / ph
            ))
            .transformed(by: CGAffineTransform(
                translationX: cropExtent.origin.x,
                y: cropExtent.origin.y
            ))
        outputImage = overlay
        isReady = true
    }

    private func heatColor(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let r: Float, g: Float, b: Float
        switch t {
        case ..<0.25:
            let s = t / 0.25
            r = 0; g = s; b = 1
        case ..<0.5:
            let s = (t - 0.25) / 0.25
            r = 0; g = 1; b = 1 - s
        case ..<0.75:
            let s = (t - 0.5) / 0.25
            r = s; g = 1; b = 0
        default:
            let s = (t - 0.75) / 0.25
            r = 1; g = 1 - s; b = 0
        }
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    private func downsampleToRGB(_ source: CIImage) -> [Float] {
        guard let buf = downsampleBuffer else { return [] }
        let pw = CGFloat(processWidth), ph = CGFloat(processHeight)
        let ext = source.extent
        let scaled = source
            .transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
            .transformed(by: CGAffineTransform(scaleX: pw / ext.width, y: ph / ext.height))
        ciContext.render(scaled, to: buf, bounds: CGRect(x: 0, y: 0, width: pw, height: ph), colorSpace: CGColorSpaceCreateDeviceRGB())
        return EulerianMagnifier.extractRGB(from: buf, width: processWidth, height: processHeight)
    }
}
