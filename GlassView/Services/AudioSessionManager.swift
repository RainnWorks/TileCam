import AVFoundation

enum AudioSessionManager {
    /// Configure the audio session for multi-stream playback.
    /// Must be called early (e.g. app launch) before any WebRTC connections.
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback allows audio even in silent mode
            // .mixWithOthers lets multiple WebRTC audio tracks coexist
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("AudioSession configuration failed: \(error)")
        }
    }
}
