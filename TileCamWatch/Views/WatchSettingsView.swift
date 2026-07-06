import SwiftUI

struct WatchSettingsView: View {
    @EnvironmentObject var session: WatchSessionManager
    @ObservedObject var settings = WatchSettings.shared

    private var wristBehaviorBinding: Binding<WristBehavior> {
        Binding(
            get: { WristBehavior(rawValue: settings.wristBehavior) ?? .eco },
            set: { newValue in
                settings.wristBehavior = newValue.rawValue
                session.syncWristBehaviorToPhone(newValue.rawValue)
            }
        )
    }

    var body: some View {
        List {
            // MARK: - When Wrist Lowers
            Section {
                WristBehaviorPickerWatch(selection: wristBehaviorBinding)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } header: {
                Text("When Wrist Lowers")
            }

            // MARK: - Glance Mode
            Section {
                Toggle(isOn: $settings.glanceModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Glance Mode")
                            .font(.body)
                        Text("Simplified camera view")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
        .onChange(of: settings.glanceModeEnabled) { _, _ in session.syncSettingsToPhone() }
        .onChange(of: settings.defaultStreamMode) { _, _ in session.syncSettingsToPhone() }
        .onChange(of: settings.streamTimeoutMinutes) { _, _ in session.syncSettingsToPhone() }
        .onChange(of: settings.glanceDefaultCamera) { _, _ in session.syncSettingsToPhone() }
    }
}
