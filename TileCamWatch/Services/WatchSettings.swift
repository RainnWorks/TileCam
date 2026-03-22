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
