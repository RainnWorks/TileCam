import SwiftUI

struct WatchSettingsView: View {
    @EnvironmentObject var session: WatchSessionManager
    @ObservedObject var settings = WatchSettings.shared

    var body: some View {
        List {
            // MARK: - Glance Mode
            Section {
                Toggle(isOn: $settings.glanceModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Glance Mode")
                            .font(.body)
                        Text("Tap for controls, tap to hide")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.glanceModeEnabled {
                    Picker("Camera", selection: $settings.glanceDefaultCamera) {
                        Text("First available")
                            .tag("")
                        ForEach(session.availableStreams, id: \.self) { name in
                            Text(name.replacingOccurrences(of: "_", with: " "))
                                .tag(name)
                        }
                    }
                }
            }

            // MARK: - Streaming
            Section {
                Picker("Default Mode", selection: $settings.defaultStreamMode) {
                    ForEach(StreamMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon)
                            .tag(mode.rawValue)
                    }
                }

                Picker("Auto-Timeout", selection: $settings.streamTimeoutMinutes) {
                    Text("Off").tag(0)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
            } header: {
                Text("Streaming")
            } footer: {
                Text("Default Mode controls audio in Glance mode. Choose Video Only for silent viewing.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
