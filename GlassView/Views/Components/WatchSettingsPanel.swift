import SwiftUI

/// Glass panel containing Watch-related settings for the iPhone app.
struct WatchSettingsPanel: View {
    @EnvironmentObject var appState: AppState
    @Binding var wristBehavior: WristBehavior
    var onDismiss: () -> Void

    @State private var visible = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Title row
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Watch")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .opacity(visible ? 1 : 0)
                            .offset(y: visible ? 0 : 4)
                            .animation(.smooth(duration: 0.3).delay(visible ? 0 : 0.06), value: visible)

                        Text("Streaming preferences")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.35))
                            .opacity(visible ? 1 : 0)
                            .animation(.smooth(duration: 0.3).delay(visible ? 0.06 : 0.03), value: visible)
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.1), in: Circle())
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .opacity(visible ? 1 : 0)
                    .animation(.smooth(duration: 0.3).delay(visible ? 0.09 : 0), value: visible)
                    .accessibilityLabel("Close")
                }

                // Wrist behavior picker
                WristBehaviorPicker(selection: $wristBehavior)
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 6)
                    .animation(.smooth(duration: 0.3).delay(visible ? 0.12 : 0), value: visible)

                Divider().overlay(.white.opacity(0.08))

                // Glance mode
                glanceModeSection
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 6)
                    .animation(.smooth(duration: 0.3).delay(visible ? 0.18 : 0), value: visible)

                Divider().overlay(.white.opacity(0.08))

                // Streaming
                streamingSection
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 6)
                    .animation(.smooth(duration: 0.3).delay(visible ? 0.24 : 0), value: visible)
            }
            .padding(24)
        }
        .frame(maxWidth: 380, maxHeight: 520)
        .contentShape(Rectangle())
        .glassBackground(cornerRadius: 24)
        .padding(.horizontal, 24)
        .onAppear { visible = true }
    }

    // MARK: - Glance Mode

    private var glanceModeSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "eye.circle")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
                Text("Glance Mode")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.watchGlanceModeEnabled },
                    set: { appState.watchGlanceModeEnabled = $0 }
                ))
                .labelsHidden()
                .tint(.green)
            }

            Text("Simplified camera view. Tap for controls.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.25))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.smooth(duration: 0.2), value: appState.watchGlanceModeEnabled)
    }

    // MARK: - Streaming

    private var streamingSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
                Text("Streaming")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }

            HStack {
                Text("Default Mode")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Picker("", selection: Binding(
                    get: { appState.watchDefaultStreamMode },
                    set: { appState.watchDefaultStreamMode = $0 }
                )) {
                    Text("Video + Audio").tag("videoAndAudio")
                    Text("Video Only").tag("videoOnly")
                    Text("Audio Only").tag("audioOnly")
                }
                .labelsHidden()
                .tint(.white.opacity(0.6))
            }

            HStack {
                Text("Auto-Timeout")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Picker("", selection: Binding(
                    get: { appState.watchStreamTimeoutMinutes },
                    set: { appState.watchStreamTimeoutMinutes = $0 }
                )) {
                    Text("Off").tag(0)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                }
                .labelsHidden()
                .tint(.white.opacity(0.6))
            }
        }
    }

    private func dismiss() {
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}
