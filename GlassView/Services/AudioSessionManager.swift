import Foundation
import os

#if canImport(AVFAudio)
import AVFAudio
#endif

private let log = Logger(subsystem: "works.rainn.tilecam", category: "AudioSession")

enum AudioSessionManager {
    static func configure() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            log.error("session configuration failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        // macOS: no AVAudioSession needed — audio plays through default output
    }

    /// Re-activate the shared audio session. iOS deactivates the session when
    /// the app is backgrounded; call this on foreground so playout can resume.
    static func activate() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
        } catch {
            log.error("session activation failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }
}
