import Accelerate
import CoreImage
import CoreVideo

/// Temporal bandpass amplification rendered as a colored overlay.
/// Breathing-frequency motion appears as a soft green/teal glow over the original video.
final class EulerianMagnifier: MotionAnalyzer {
    private(set) var isReady = false
    private(set) var outputImage: CIImage?

    private let processWidth = 160
    private let processHeight = 90
    private let amplification: Float = 40.0
    private let freqLow: Float = 0.1
    private let freqHigh: Float = 1.0
    private let warmupFrames = 30
    private let noiseGate: Float = 0.003

    private var lowpassSlow: [Float]?
    private var lowpassFast: [Float]?
    private var lastTimestamp: TimeInterval = 0
    private var frameCount = 0

    private let ciContext: CIContext
    private var processBuffer: CVPixelBuffer?
    private var outputBuffer: CVPixelBuffer?

    init() {
        ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        processBuffer = Self.makeBuffer(width: processWidth, height: processHeight)
        outputBuffer = Self.makeBuffer(width: processWidth, height: processHeight)
    }

    func reset() {
        lowpassSlow = nil
        lowpassFast = nil
        lastTimestamp = 0
        frameCount = 0
        isReady = false
        outputImage = nil
    }

    func feed(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, viewport: MotionViewport) {
        let fullImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cropped = viewport.crop(fullImage)
        let cropExtent = cropped.extent
        guard cropExtent.width > 0, cropExtent.height > 0,
              let pb = processBuffer, let outBuf = outputBuffer else { return }

        let dt = timestamp - lastTimestamp
        lastTimestamp = timestamp

        let pw = CGFloat(processWidth)
        let ph = CGFloat(processHeight)
        let downsampled = cropped
            .transformed(by: CGAffineTransform(translationX: -cropExtent.origin.x, y: -cropExtent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: pw / cropExtent.width, y: ph / cropExtent.height))
        ciContext.render(downsampled, to: pb, bounds: CGRect(x: 0, y: 0, width: pw, height: ph), colorSpace: CGColorSpaceCreateDeviceRGB())

        let pixelCount = processWidth * processHeight
        let channelCount = pixelCount * 3
        let rgb = Self.extractRGB(from: pb, width: processWidth, height: processHeight)
        guard rgb.count == channelCount else { return }

        if lowpassSlow == nil || dt <= 0 || dt > 2.0 {
            lowpassSlow = rgb
            lowpassFast = rgb
            frameCount = 0
            isReady = false
            return
        }

        frameCount += 1
        let alphaSlow = 1 - exp(-2 * Float.pi * freqLow * Float(dt))
        let alphaFast = 1 - exp(-2 * Float.pi * freqHigh * Float(dt))
        let n = vDSP_Length(channelCount)

        var diffSlow = [Float](repeating: 0, count: channelCount)
        var diffFast = [Float](repeating: 0, count: channelCount)
        vDSP_vsub(lowpassSlow!, 1, rgb, 1, &diffSlow, 1, n)
        vDSP_vsub(lowpassFast!, 1, rgb, 1, &diffFast, 1, n)
        var aS = alphaSlow, aF = alphaFast
        vDSP_vsma(diffSlow, 1, &aS, lowpassSlow!, 1, &lowpassSlow!, 1, n)
        vDSP_vsma(diffFast, 1, &aF, lowpassFast!, 1, &lowpassFast!, 1, n)

        var bandpass = [Float](repeating: 0, count: channelCount)
        vDSP_vsub(lowpassSlow!, 1, lowpassFast!, 1, &bandpass, 1, n)

        CVPixelBufferLockBaseAddress(outBuf, [])
        let base = CVPixelBufferGetBaseAddress(outBuf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(outBuf)
        for y in 0..<processHeight {
            let row = y * bpr
            for x in 0..<processWidth {
                let i = y * processWidth + x
                let r = bandpass[i]
                let g = bandpass[pixelCount + i]
                let b = bandpass[pixelCount * 2 + i]
                let mag = (abs(r) + abs(g) + abs(b)) / 3.0
                let off = row + x * 4
                guard mag > noiseGate else {
                    base[off] = 0; base[off + 1] = 0; base[off + 2] = 0; base[off + 3] = 0
                    continue
                }
                let intensity = min(mag * amplification, 1.0)
                let a = UInt8(intensity * 160)
                base[off] = UInt8(180 * intensity)      // B
                base[off + 1] = UInt8(255 * intensity)  // G
                base[off + 2] = UInt8(80 * intensity)   // R
                base[off + 3] = a
            }
        }
        CVPixelBufferUnlockBaseAddress(outBuf, [])

        // Scale overlay back to crop region size and position in the full frame
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

        if frameCount >= warmupFrames { isReady = true }
    }

    // MARK: - Pixel Helpers

    static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary, &pb)
        return pb
    }

    static func extractRGB(from buffer: CVPixelBuffer, width: Int, height: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let pixelCount = width * height
        var rgb = [Float](repeating: 0, count: pixelCount * 3)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width {
                let i = y * width + x
                let b = row + x * 4
                rgb[i] = Float(ptr[b + 2]) / 255.0
                rgb[pixelCount + i] = Float(ptr[b + 1]) / 255.0
                rgb[pixelCount * 2 + i] = Float(ptr[b]) / 255.0
            }
        }
        return rgb
    }
}
