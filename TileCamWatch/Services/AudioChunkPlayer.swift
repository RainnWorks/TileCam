import AVFoundation
import os

private let log = Logger(subsystem: "works.rainn.tilecam.watch", category: "Audio")

/// Max number of buffers queued on AVAudioPlayerNode before we start dropping.
/// ~20 chunks at ~4KB ≈ 2-3 seconds of audio. Beyond this we assume drift.
private let maxQueuedBuffers = 20

/// Plays MP3 audio chunks received from the iPhone via WatchConnectivity.
/// Writes each chunk to a temp file and schedules it as a PCM buffer on AVAudioPlayerNode.
@MainActor
final class AudioChunkPlayer: ObservableObject {
    @Published var isPlaying = false

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var chunkIndex = 0
    private let tempDir: URL

    /// Fix #5: Track queued buffer count for drift detection.
    private var queuedBufferCount = 0

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tilecam_audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempDir = dir
    }

    func start() {
        guard engine == nil else { return }

        configureAudioSession()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        // Connect at a standard PCM format — decoded MP3 will be converted to this
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        do {
            try engine.start()
            player.play()
            self.engine = engine
            self.playerNode = player
            self.queuedBufferCount = 0
            isPlaying = true
            log.info("Audio engine started")
        } catch {
            log.error("Failed to start audio engine: \(error)")
        }
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        queuedBufferCount = 0
        isPlaying = false
        cleanupTempFiles()
        log.info("Audio engine stopped")
    }

    func enqueue(mp3Data: Data) {
        guard let playerNode, let engine, engine.isRunning else { return }

        // Fix #5: Drop incoming audio if too far behind (drift protection)
        if queuedBufferCount >= maxQueuedBuffers {
            log.warning("Audio queue saturated (\(self.queuedBufferCount) buffers), dropping to reduce drift")
            // Flush all queued audio and restart from this point
            playerNode.stop()
            playerNode.play()
            queuedBufferCount = 0
        }

        // Write MP3 chunk to temp file for AVAudioFile to read
        let fileURL = tempDir.appendingPathComponent("chunk_\(chunkIndex).mp3")
        chunkIndex += 1

        do {
            try mp3Data.write(to: fileURL)
            let audioFile = try AVAudioFile(forReading: fileURL)
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard frameCount > 0 else { return }

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: frameCount
            ) else { return }

            try audioFile.read(into: buffer)

            // Convert to output format if needed
            let outputFormat = engine.outputNode.outputFormat(forBus: 0)
            if buffer.format == outputFormat {
                scheduleWithTracking(buffer, on: playerNode)
            } else if let converter = AVAudioConverter(from: buffer.format, to: outputFormat) {
                let convertedCapacity = AVAudioFrameCount(
                    Double(frameCount) * outputFormat.sampleRate / buffer.format.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: convertedCapacity
                ) else { return }

                var error: NSError?
                var isDone = false
                converter.convert(to: converted, error: &error) { _, outStatus in
                    if isDone {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    isDone = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if error == nil && converted.frameLength > 0 {
                    scheduleWithTracking(converted, on: playerNode)
                }
            }

            // Clean up old temp files (keep last 5)
            if chunkIndex % 10 == 0 {
                cleanupOldChunks()
            }
        } catch {
            log.error("Failed to enqueue audio chunk: \(error)")
        }
    }

    /// Schedules a buffer and tracks queue depth for drift detection.
    private func scheduleWithTracking(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode) {
        queuedBufferCount += 1
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                self?.queuedBufferCount -= 1
            }
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        #if os(watchOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            log.error("Audio session config failed: \(error)")
        }
        #endif
    }

    // MARK: - Cleanup

    private var lastCleanedIndex = 0

    private func cleanupOldChunks() {
        let keepAfter = max(0, chunkIndex - 5)
        guard keepAfter > lastCleanedIndex else { return }
        for i in lastCleanedIndex..<keepAfter {
            let url = tempDir.appendingPathComponent("chunk_\(i).mp3")
            try? FileManager.default.removeItem(at: url)
        }
        lastCleanedIndex = keepAfter
    }

    private func cleanupTempFiles() {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        chunkIndex = 0
        lastCleanedIndex = 0
    }
}
