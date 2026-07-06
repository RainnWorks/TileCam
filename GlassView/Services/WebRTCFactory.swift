import WebRTC

/// Thread-safe, non-isolated factory holder.
/// Call `ensureReady()` early from a background thread to avoid blocking main.
final class WebRTCFactory: @unchecked Sendable {
    static let shared = WebRTCFactory()

    private let queue = DispatchQueue(label: "works.rainn.tilecam.webrtc.factory")
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

    /// Recover the shared playout engine after returning to the foreground.
    /// `playbackDevice` is eagerly constructed, so this always acts on a real
    /// device; the recovery itself is idempotent.
    func resumePlayout() {
        playbackDevice.resumePlayoutIfNeeded()
    }

    /// Stop the shared playout engine and deactivate the audio session so iOS
    /// can suspend the app on background. Call when background audio is not
    /// wanted (no opt-in toggle, no genuine PiP window). `playbackDevice` is
    /// eagerly constructed, so this always acts on a real device.
    func suspendPlayout() {
        playbackDevice.suspendPlayout()
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
