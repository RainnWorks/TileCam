import Accelerate
import CoreImage
import CoreVideo

/// Visualizes per-pixel brightness changes as directional color overlay.
/// Brightening pixels render as cyan, dimming pixels as orange.
/// Only motion above the noise floor is colored — camera shows through everywhere else.
final class MotionFlowAnalyzer: MotionAnalyzer {
    private(set) var isReady = false
    private(set) var outputImage: CIImage?

    private let processWidth = 160
    private let processHeight = 90
    private let smoothingAlpha: Float = 0.15
    private let sensitivity: Float = 5.0
    private let noiseFloor: Float = 0.006

    private var previousLuma: [Float]?
    private var smoothedDiff: [Float]?
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
        smoothedDiff = nil
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
            smoothedDiff = [Float](repeating: 0, count: pixelCount)
            return
        }

        var diff = [Float](repeating: 0, count: pixelCount)
        vDSP_vsub(prev, 1, luma, 1, &diff, 1, n)

        for i in 0..<pixelCount {
            if abs(diff[i]) < noiseFloor { diff[i] = 0 }
        }

        var alpha = smoothingAlpha
        var delta = [Float](repeating: 0, count: pixelCount)
        vDSP_vsub(smoothedDiff!, 1, diff, 1, &delta, 1, n)
        vDSP_vsma(delta, 1, &alpha, smoothedDiff!, 1, &smoothedDiff!, 1, n)

        previousLuma = luma

        CVPixelBufferLockBaseAddress(outBuf, [])
        let base = CVPixelBufferGetBaseAddress(outBuf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(outBuf)
        for y in 0..<processHeight {
            let row = y * bpr
            for x in 0..<processWidth {
                let i = y * processWidth + x
                let v = smoothedDiff![i] * sensitivity
                let mag = min(abs(v), 1.0)
                let b = row + x * 4
                guard mag > 0.01 else {
                    base[b] = 0; base[b + 1] = 0; base[b + 2] = 0; base[b + 3] = 0
                    continue
                }
                let a = UInt8(mag * 160)
                if v > 0 {
                    base[b] = UInt8(200 * mag); base[b + 1] = UInt8(220 * mag); base[b + 2] = UInt8(80 * mag); base[b + 3] = a
                } else {
                    base[b] = UInt8(40 * mag); base[b + 1] = UInt8(100 * mag); base[b + 2] = UInt8(220 * mag); base[b + 3] = a
                }
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
