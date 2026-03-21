import WebRTC

/// Thread-safe, non-isolated factory holder.
/// Call `ensureReady()` early from a background thread to avoid blocking main.
final class WebRTCFactory: @unchecked Sendable {
    static let shared = WebRTCFactory()

    private let queue = DispatchQueue(label: "com.glassview.webrtc.factory")
    private var _factory: RTCPeerConnectionFactory?
    private let playbackDevice = PlaybackOnlyAudioDevice()

    var factory: RTCPeerConnectionFactory {
        queue.sync {
            if _factory == nil { _init() }
            return _factory!
        }
    }

    func ensureReady() {
        queue.sync {
            if _factory == nil { _init() }
        }
    }

    private func _init() {
        RTCInitializeSSL()
        _factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory(),
            audioDevice: playbackDevice
        )
    }
}
