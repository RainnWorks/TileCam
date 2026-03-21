import AVFoundation
import WebRTC

/// A custom RTCAudioDevice that only handles playout (speaker output).
/// Recording methods are all no-ops, so the microphone is never activated.
final class PlaybackOnlyAudioDevice: NSObject, RTCAudioDevice {
    private var audioDelegate: RTCAudioDeviceDelegate?
    private var displayLink: CADisplayLink?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    private var _isInitialized = false
    private var _isPlayoutInitialized = false
    private var _isPlaying = false

    private let sampleRate: Double = 48000
    private let channels: Int = 1
    private let ioDuration: TimeInterval = 0.02 // 20ms

    // MARK: - Input properties (no-op, no mic)
    var deviceInputSampleRate: Double { sampleRate }
    var inputIOBufferDuration: TimeInterval { ioDuration }
    var inputNumberOfChannels: Int { 0 }
    var inputLatency: TimeInterval { 0 }

    // MARK: - Output properties
    var deviceOutputSampleRate: Double { sampleRate }
    var outputIOBufferDuration: TimeInterval { ioDuration }
    var outputNumberOfChannels: Int { channels }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { _isInitialized }
    var isPlayoutInitialized: Bool { _isPlayoutInitialized }
    var isPlaying: Bool { _isPlaying }
    var isRecordingInitialized: Bool { true }
    var isRecording: Bool { false }

    // MARK: - Lifecycle

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        audioDelegate = delegate
        _isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        stopPlayout()
        audioDelegate = nil
        _isInitialized = false
        return true
    }

    // MARK: - Playout

    func initializePlayout() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setPreferredSampleRate(sampleRate)
            try session.setPreferredIOBufferDuration(ioDuration)
            try session.setActive(true)
        } catch {
            print("PlaybackOnlyAudioDevice: session config failed: \(error)")
            return false
        }
        _isPlayoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        guard let delegate = audioDelegate else { return false }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!

        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        // Install a tap-less render callback using a source node
        let frameCount = UInt32(sampleRate * ioDuration)
        let getPlayoutData = delegate.getPlayoutData

        let srcNode = AVAudioSourceNode(format: format) { (_, timestamp, frameCountVal, audioBufferList) -> OSStatus in
            var flags = AudioUnitRenderActionFlags()
            return getPlayoutData(&flags, timestamp, 0, frameCountVal, audioBufferList)
        }

        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            player.play()
        } catch {
            print("PlaybackOnlyAudioDevice: engine start failed: \(error)")
            return false
        }

        self.audioEngine = engine
        self.playerNode = player
        _isPlaying = true
        return true
    }

    func stopPlayout() -> Bool {
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        _isPlaying = false
        return true
    }

    // MARK: - Recording (all no-ops)

    func initializeRecording() -> Bool { true }
    func startRecording() -> Bool { true }
    func stopRecording() -> Bool { true }
}
