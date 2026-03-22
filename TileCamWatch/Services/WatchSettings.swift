import SwiftUI

/// Persisted settings for the TileCam Watch app.
final class WatchSettings: ObservableObject {
    static let shared = WatchSettings()

    /// Streaming timeout in minutes. 0 = no timeout.
    @AppStorage("streamTimeoutMinutes") var streamTimeoutMinutes: Int = 60

    /// Glance mode: raise wrist → see last/default camera → lower wrist → done.
    /// No toolbar, no controls. Long-press for options.
    @AppStorage("glanceModeEnabled") var glanceModeEnabled: Bool = false

    /// Default camera for Glance mode. Empty = first available.
    @AppStorage("glanceDefaultCamera") var glanceDefaultCamera: String = ""

    /// Default stream mode for new sessions.
    @AppStorage("defaultStreamMode") var defaultStreamMode: String = StreamMode.videoAndAudio.rawValue

    /// Wrist-down behavior: "eco" (stop all), "audioOnly" (keep audio), "alwaysOn" (keep both).
    /// Synced from the iPhone app.
    @AppStorage("wristBehavior") var wristBehavior: String = "eco"

    /// Whether to keep audio playing when wrist is lowered.
    var keepAudioOnWristDown: Bool {
        wristBehavior == "audioOnly" || wristBehavior == "alwaysOn"
    }

    /// Whether to keep video streaming when wrist is lowered.
    var keepVideoOnWristDown: Bool {
        wristBehavior == "alwaysOn"
    }

    var resolvedMode: StreamMode {
        StreamMode(rawValue: defaultStreamMode) ?? .videoAndAudio
    }

    var timeoutSeconds: TimeInterval {
        TimeInterval(streamTimeoutMinutes) * 60
    }

    var hasTimeout: Bool {
        streamTimeoutMinutes > 0
    }
}
