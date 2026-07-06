import SwiftUI

/// Glass panel containing general iPhone app settings.
struct SettingsPanel: View {
    @EnvironmentObject var appState: AppState
    var onDismiss: () -> Void

    @State private var visible = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Title row
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .opacity(visible ? 1 : 0)
                            .offset(y: visible ? 0 : 4)
                            .animation(.smooth(duration: 0.3).delay(visible ? 0 : 0.06), value: visible)

                        Text("App preferences")
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

                displaySection
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 6)
                    .animation(.smooth(duration: 0.3).delay(visible ? 0.12 : 0), value: visible)

                Divider().overlay(.white.opacity(0.08))

                audioSection
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 6)
                    .animation(.smooth(duration: 0.3).delay(visible ? 0.18 : 0), value: visible)
            }
            .padding(24)
        }
        .frame(maxWidth: 380, maxHeight: 520)
        .contentShape(Rectangle())
        .glassBackground(cornerRadius: 24)
        .padding(.horizontal, 24)
        .onAppear { visible = true }
    }

    // MARK: - Display

    private var displaySection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "iphone.gen3")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
                Text("Display")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Screen Awake")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Prevents auto-lock while streams are open.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.25))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.keepScreenAwake },
                    set: { appState.keepScreenAwake = $0 }
                ))
                .labelsHidden()
                .tint(.green)
            }

            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dim Video")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Darkens the video for night viewing.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.videoDimmingEnabled },
                        set: { appState.videoDimmingEnabled = $0 }
                    ))
                    .labelsHidden()
                    .tint(.green)
                }

                if appState.videoDimmingEnabled {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.max")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                        Slider(
                            value: Binding(
                                get: { appState.videoDimmingAmount },
                                set: { appState.videoDimmingAmount = $0 }
                            ),
                            in: 0.0...0.9
                        )
                        .tint(.white.opacity(0.6))
                        Image(systemName: "moon.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                        Text("\(Int(appState.videoDimmingAmount * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 34, alignment: .trailing)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: appState.keepScreenAwake)
        .animation(.smooth(duration: 0.2), value: appState.videoDimmingEnabled)
    }

    // MARK: - Audio

    private var audioSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "speaker.wave.2")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
                Text("Audio")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background Audio")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Keep playing audio when the app is backgrounded.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.25))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.backgroundAudioEnabled },
                    set: { appState.backgroundAudioEnabled = $0 }
                ))
                .labelsHidden()
                .tint(.green)
            }
        }
        .animation(.smooth(duration: 0.2), value: appState.backgroundAudioEnabled)
    }

    private func dismiss() {
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}
