import Foundation

#if canImport(AVFAudio)
import AVFAudio
#endif

enum AudioSessionManager {
    static func configure() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("AudioSession configuration failed: \(error)")
        }
        #endif
        // macOS: no AVAudioSession needed — audio plays through default output
    }
}
