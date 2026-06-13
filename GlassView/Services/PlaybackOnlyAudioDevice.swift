import AVFoundation
import WebRTC
import os

private let log = Logger(subsystem: "works.rainn.tilecam", category: "AudioDevice")

/// A custom RTCAudioDevice that only handles playout (speaker output).
/// Recording methods are all no-ops, so the microphone is never activated.
///
/// There is a single, process-global instance of this device (owned by
/// `WebRTCFactory`). All inbound audio tracks are mixed by WebRTC into the one
/// `getPlayoutData` pull, so the single `AVAudioEngine` here drives every
/// stream's audio simultaneously.
///
/// iOS stops the underlying engine on interruptions / backgrounding / media
/// reset. Without recovery the engine stays dead while `_isPlaying` lies that
/// it's running, so WebRTC never rebuilds playout and only a full app kill
/// recovers audio. The observers below rebuild and restart the engine on those
/// events. All engine state is mutated on `engineQueue` to stay consistent.
final class PlaybackOnlyAudioDevice: NSObject, RTCAudioDevice {
    private var audioDelegate: RTCAudioDeviceDelegate?
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    private var _isInitialized = false
    private var _isPlayoutInitialized = false
    private var _isPlaying = false

    /// Serializes all engine build/teardown so observer callbacks and the
    /// RTCAudioDevice lifecycle calls don't race.
    private let engineQueue = DispatchQueue(label: "works.rainn.tilecam.audiodevice")

    private let sampleRate: Double = 48000
    private let channels: Int = 1
    private let ioDuration: TimeInterval = 0.02

    override init() {
        super.init()
        registerObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

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
    // Read from WebRTC's ADM thread; serialize on engineQueue so WebRTC can't
    // see a stale `true` while the engine is stopped mid-rebuild. WebRTC never
    // reads this from a thread already on engineQueue, so sync is deadlock-free.
    var isPlaying: Bool { engineQueue.sync { _isPlaying } }
    var isRecordingInitialized: Bool { true }
    var isRecording: Bool { false }

    // MARK: - Lifecycle

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        audioDelegate = delegate
        _isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        audioDelegate = nil
        _isInitialized = false
        return true
    }

    // MARK: - Playout

    func initializePlayout() -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setPreferredSampleRate(sampleRate)
            try session.setPreferredIOBufferDuration(ioDuration)
            try session.setActive(true)
        } catch {
            log.error("session config failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #endif
        _isPlayoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        engineQueue.sync { buildAndStartEngineLocked() }
    }

    func stopPlayout() -> Bool {
        engineQueue.sync { stopEngineLocked() }
        return true
    }

    /// Public hook to recover playout after returning to the foreground, where
    /// no AVAudioSession/engine notification may have fired. Idempotent.
    func resumePlayoutIfNeeded() {
        restartIfNeeded()
    }

    /// Stop the engine AND deactivate the shared audio session so iOS can
    /// release the background-audio assertion when the app suspends. Mirrors
    /// `resumePlayoutIfNeeded()` for the suspend direction. Idempotent.
    func suspendPlayout() {
        engineQueue.sync {
            stopEngineLocked()
            #if os(iOS)
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation
                )
            } catch {
                log.error("session deactivate failed: \(error.localizedDescription, privacy: .public)")
            }
            #endif
        }
    }

    // MARK: - Recording (all no-ops)

    func initializeRecording() -> Bool { true }
    func startRecording() -> Bool { true }
    func stopRecording() -> Bool { true }

    // MARK: - Engine management (all callers hold engineQueue)

    /// Builds (or rebuilds) the engine and starts playout. Idempotent: if the
    /// engine is already running, this is a no-op that keeps `_isPlaying` true.
    @discardableResult
    private func buildAndStartEngineLocked() -> Bool {
        guard let delegate = audioDelegate else {
            log.error("buildAndStartEngine: no audio delegate")
            return false
        }

        // Don't double-start a healthy engine.
        if let engine = audioEngine, engine.isRunning {
            _isPlaying = true
            return true
        }

        // Tear down any stale (stopped) engine before rebuilding.
        stopEngineLocked()

        let engine = AVAudioEngine()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!

        let getPlayoutData = delegate.getPlayoutData
        let srcNode = AVAudioSourceNode(format: format) { (_, timestamp, frameCountVal, audioBufferList) -> OSStatus in
            var flags = AudioUnitRenderActionFlags()
            return getPlayoutData(&flags, timestamp, 0, frameCountVal, audioBufferList)
        }

        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            log.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            // Leave flags honest: engine is not running.
            self.audioEngine = nil
            self.sourceNode = nil
            _isPlaying = false
            return false
        }

        self.audioEngine = engine
        self.sourceNode = srcNode
        // Gate the flag on the actual engine state, never blindly true.
        _isPlaying = engine.isRunning
        log.info("playout engine started (running=\(engine.isRunning))")
        return _isPlaying
    }

    private func stopEngineLocked() {
        audioEngine?.stop()
        if let node = sourceNode {
            audioEngine?.detach(node)
        }
        audioEngine = nil
        sourceNode = nil
        _isPlaying = false
    }

    /// Rebuild + restart the engine after an interruption / reset, if we're
    /// supposed to be playing. Re-activates the session first.
    private func restartIfNeeded() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            guard self._isPlayoutInitialized else { return }
            // If the engine is already running, nothing to do.
            if let engine = self.audioEngine, engine.isRunning {
                self._isPlaying = true
                return
            }
            #if os(iOS)
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                log.error("session reactivate failed: \(error.localizedDescription, privacy: .public)")
            }
            #endif
            self.buildAndStartEngineLocked()
        }
    }

    // MARK: - Observers

    private func registerObservers() {
        let center = NotificationCenter.default
        #if os(iOS)
        center.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil
        )
        #endif
        center.addObserver(
            self, selector: #selector(handleConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange, object: nil
        )
    }

    #if os(iOS)
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            log.info("interruption began — stopping engine")
            engineQueue.async { [weak self] in
                self?.audioEngine?.stop()
                // Honest flags: the engine is no longer running.
                self?._isPlaying = false
            }
        case .ended:
            log.info("interruption ended — restarting engine")
            restartIfNeeded()
        @unknown default:
            break
        }
    }

    @objc private func handleMediaServicesReset(_ note: Notification) {
        log.warning("media services reset — rebuilding engine")
        // The whole audio stack is gone; force a full rebuild.
        engineQueue.async { [weak self] in
            self?.stopEngineLocked()
        }
        restartIfNeeded()
    }
    #endif

    @objc private func handleConfigurationChange(_ note: Notification) {
        // engine.connect(...)/engine.start() themselves post this notification,
        // so only rebuild when we have an engine that has actually stopped.
        // Otherwise this is a no-op (avoids a redundant rebuild on every normal
        // build and an audio-dropping stop/rebuild on route changes while live).
        engineQueue.async { [weak self] in
            guard let self else { return }
            guard let engine = self.audioEngine, !engine.isRunning else { return }
            log.info("engine configuration change — engine stopped, restarting")
            self.restartIfNeeded()
        }
    }
}
