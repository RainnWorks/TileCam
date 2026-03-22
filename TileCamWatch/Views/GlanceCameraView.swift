import SwiftUI

/// Auto-hide delay for tap-to-reveal controls.
private let controlsFadeDelay: TimeInterval = 4

/// Zero-interaction camera view for Glance mode.
/// Tap to reveal controls (mode, camera switch, exit glance). Tap again or wait to hide.
struct GlanceCameraView: View {
    @EnvironmentObject var session: WatchSessionManager
    @ObservedObject var settings = WatchSettings.shared
    @Binding var showSettings: Bool

    @State private var showControls = false
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var showCameraPicker = false
    @State private var timeoutTask: Task<Void, Never>?
    @State private var isFrameStale = false
    @State private var stalenessTimer: Task<Void, Never>?
    @State private var selectedMode: StreamMode = .videoAndAudio

    private var resolvedCameraName: String? {
        if !settings.glanceDefaultCamera.isEmpty,
           session.availableStreams.contains(settings.glanceDefaultCamera) {
            return settings.glanceDefaultCamera
        }
        return session.availableStreams.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !session.isPhoneReachable {
                glanceNotReachable
            } else if resolvedCameraName != nil {
                glanceCameraContent
            } else {
                glanceNoCameras
            }
        }
        .onAppear {
            selectedMode = settings.resolvedMode
            startGlance()
        }
        .onDisappear { stopGlance() }
        .onChange(of: session.isPhoneReachable) { _, reachable in
            if reachable { startGlance() }
        }
        .onChange(of: session.lastFrameTime) { _, _ in
            isFrameStale = false
            resetStalenessTimer()
            resetTimeout()
        }
        .sheet(isPresented: $showCameraPicker) {
            glanceCameraPicker
        }
    }

    // MARK: - Camera Content

    private var glanceCameraContent: some View {
        ZStack {
            // Video frame
            if let image = session.latestSnapshot {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(session.isStreamPaused ? 0.4 : (isFrameStale ? 0.7 : 1.0))
                    .animation(.easeInOut(duration: 0.4), value: session.isStreamPaused)
                    .animation(.easeInOut(duration: 0.4), value: isFrameStale)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "video.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.2))
                        .symbolEffect(.pulse, isActive: session.isSubscribing)
                    if let name = resolvedCameraName {
                        Text(name.replacingOccurrences(of: "_", with: " "))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }

            // Status overlays (priority: paused > frozen)
            if session.isStreamPaused {
                VStack(spacing: 4) {
                    Image(systemName: "pause.circle")
                        .font(.title3)
                        .foregroundStyle(.orange.opacity(0.8))
                    Text("iPhone in background")
                        .font(.system(size: 9).weight(.medium))
                        .foregroundStyle(.orange.opacity(0.6))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if isFrameStale && session.latestSnapshot != nil {
                frozenBadge
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            // Always-visible: subtle camera name + audio indicator
            if session.latestSnapshot != nil && !showControls {
                persistentHUD
            }

            // Tap-to-reveal controls
            if showControls {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .animation(.easeInOut(duration: 0.25), value: showControls)
    }

    // MARK: - Persistent HUD (always visible, minimal)

    private var persistentHUD: some View {
        VStack {
            HStack {
                if let name = resolvedCameraName {
                    Text(name.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 9).weight(.medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.25), in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            Spacer()

            // Audio indicator
            if session.audioPlayer.isPlaying {
                HStack(spacing: 3) {
                    Image(systemName: "waveform")
                        .font(.system(size: 8))
                    Text("Audio")
                        .font(.system(size: 8))
                }
                .foregroundStyle(.green.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Controls Overlay (tap to show/hide)

    private var controlsOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                // Mode cycle
                Button { cycleMode() } label: {
                    Image(systemName: selectedMode.icon)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.15), in: Circle())
                }

                // Camera switch
                if session.availableStreams.count > 1 {
                    Button { showCameraPicker = true } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                }

                Spacer()

                // Exit Glance → switch to standard mode
                Button {
                    settings.glanceModeEnabled = false
                } label: {
                    Image(systemName: "rectangle.grid.1x2")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.15), in: Circle())
                }

                // Settings
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.15), in: Circle())
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Controls Toggle

    private func toggleControls() {
        if showControls {
            hideControls()
        } else {
            showControls = true
            scheduleAutoHide()
        }
    }

    private func hideControls() {
        showControls = false
        controlsHideTask?.cancel()
        controlsHideTask = nil
    }

    private func scheduleAutoHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(controlsFadeDelay))
            guard !Task.isCancelled else { return }
            showControls = false
        }
    }

    // MARK: - Mode Cycling

    private func cycleMode() {
        let allModes = StreamMode.allCases
        guard let idx = allModes.firstIndex(of: selectedMode) else { return }
        selectedMode = allModes[(idx + 1) % allModes.count]
        session.changeMode(selectedMode)
        scheduleAutoHide()
    }

    // MARK: - Frozen Badge

    private var frozenBadge: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 2) {
                    Circle().fill(.yellow).frame(width: 4, height: 4)
                    Text("Frozen")
                        .font(.system(size: 8).weight(.medium))
                        .foregroundStyle(.yellow)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            Spacer()
        }
    }

    // MARK: - Empty States

    private var glanceNotReachable: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.3))
                .symbolEffect(.pulse)
            Text("Waiting for iPhone")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private var glanceNoCameras: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.3))
            Text("No cameras")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    // MARK: - Camera Picker

    private var glanceCameraPicker: some View {
        NavigationStack {
            List(session.availableStreams, id: \.self) { name in
                Button {
                    showCameraPicker = false
                    settings.glanceDefaultCamera = name
                    session.unsubscribe()
                    session.subscribe(to: name, mode: selectedMode)
                    hideControls()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "video.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(name.replacingOccurrences(of: "_", with: " "))
                            .font(.body)
                        if name == resolvedCameraName {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .listStyle(.carousel)
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Lifecycle

    private func startGlance() {
        guard session.isPhoneReachable, let camera = resolvedCameraName else { return }

        // If already subscribed to this camera (e.g. wrist-raise after audio-only or always-on),
        // just restore the user's preferred mode instead of re-subscribing from scratch.
        if session.subscribedStream == camera {
            if session.currentMode != selectedMode {
                session.changeMode(selectedMode)
            }
            resetTimeout()
            resetStalenessTimer()
            return
        }

        session.subscribe(to: camera, mode: selectedMode)
        resetTimeout()
        resetStalenessTimer()
    }

    private func stopGlance() {
        timeoutTask?.cancel()
        stalenessTimer?.cancel()
        controlsHideTask?.cancel()

        // Respect wrist-down behavior setting
        if settings.keepAudioOnWristDown && !settings.keepVideoOnWristDown {
            // Audio-only: switch to audio mode, keep streaming
            if session.currentMode != .audioOnly {
                session.changeMode(.audioOnly)
            }
        } else if settings.keepVideoOnWristDown {
            // Always-on: keep everything running (skip unsubscribe)
        } else {
            // Eco: stop everything
            session.unsubscribe()
        }
    }

    private func resetTimeout() {
        timeoutTask?.cancel()
        guard settings.hasTimeout else { return }
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(settings.timeoutSeconds))
            guard !Task.isCancelled else { return }
            session.unsubscribe()
        }
    }

    private func resetStalenessTimer() {
        stalenessTimer?.cancel()
        isFrameStale = false
        stalenessTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if session.subscribedStream != nil && !session.isStreamPaused {
                isFrameStale = true
            }
        }
    }
}
