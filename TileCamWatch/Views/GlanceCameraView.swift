import SwiftUI

/// Zero-interaction camera view for Glance mode.
/// Shows the camera feed full-screen with no chrome.
/// Long-press to access options. Auto-subscribes on appear, unsubscribes on disappear.
struct GlanceCameraView: View {
    @EnvironmentObject var session: WatchSessionManager
    @ObservedObject var settings = WatchSettings.shared
    @Binding var showSettings: Bool

    @State private var showOptions = false
    @State private var showCameraPicker = false
    @State private var timeoutTask: Task<Void, Never>?
    @State private var isFrameStale = false
    @State private var stalenessTimer: Task<Void, Never>?

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
            } else if let _ = resolvedCameraName {
                glanceCameraContent
            } else {
                glanceNoCameras
            }
        }
        .onAppear { startGlance() }
        .onDisappear { stopGlance() }
        .onChange(of: session.isPhoneReachable) { _, reachable in
            if reachable { startGlance() }
        }
        .onChange(of: session.lastFrameTime) { _, _ in
            isFrameStale = false
            resetStalenessTimer()
            resetTimeout()
        }
    }

    // MARK: - Camera Content

    private var glanceCameraContent: some View {
        ZStack {
            if let image = session.latestSnapshot {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                        .tint(.white.opacity(0.5))
                    if let name = resolvedCameraName {
                        Text(name.replacingOccurrences(of: "_", with: " "))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }

            // Subtle camera name pill — top left, fades after frames arrive
            if session.latestSnapshot != nil {
                VStack {
                    HStack {
                        if let name = resolvedCameraName {
                            Text(name.replacingOccurrences(of: "_", with: " "))
                                .font(.system(size: 9).weight(.medium))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.3), in: Capsule())
                        }
                        Spacer()

                        // Staleness indicator
                        if isFrameStale && !session.isStreamPaused {
                            frozenBadge
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    Spacer()
                }
                .animation(.easeInOut(duration: 0.3), value: isFrameStale)
            }

            // Paused overlay
            if session.isStreamPaused {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 4) {
                    Image(systemName: "pause.circle")
                        .font(.title3)
                        .foregroundStyle(.orange.opacity(0.8))
                    Text("iPhone in background")
                        .font(.system(size: 9).weight(.medium))
                        .foregroundStyle(.orange.opacity(0.6))
                }
                .transition(.opacity)
            }

            // Audio indicator
            if session.audioPlayer.isPlaying {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "waveform")
                            .font(.system(size: 8))
                            .foregroundStyle(.green.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5) {
            showOptions = true
        }
        .confirmationDialog("Options", isPresented: $showOptions) {
            if session.availableStreams.count > 1 {
                Button("Switch Camera") { showCameraPicker = true }
            }
            Button("Settings") { showSettings = true }
            Button("Exit Glance") {
                settings.glanceModeEnabled = false
            }
        }
        .sheet(isPresented: $showCameraPicker) {
            glanceCameraPicker
        }
    }

    // MARK: - States

    private var glanceNotReachable: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.slash")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.3))
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

    private var frozenBadge: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(.yellow)
                .frame(width: 4, height: 4)
            Text("Frozen")
                .font(.system(size: 8).weight(.medium))
                .foregroundStyle(.yellow)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.5), in: Capsule())
    }

    // MARK: - Camera Picker

    private var glanceCameraPicker: some View {
        NavigationStack {
            List(session.availableStreams, id: \.self) { name in
                Button {
                    showCameraPicker = false
                    settings.glanceDefaultCamera = name
                    session.unsubscribe()
                    session.subscribe(to: name, mode: settings.resolvedMode)
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
        guard session.subscribedStream != camera else { return }
        session.subscribe(to: camera, mode: settings.resolvedMode)
        resetTimeout()
        resetStalenessTimer()
    }

    private func stopGlance() {
        timeoutTask?.cancel()
        stalenessTimer?.cancel()
        session.unsubscribe()
    }

    private func resetTimeout() {
        timeoutTask?.cancel()
        guard settings.hasTimeout else { return }
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(settings.timeoutSeconds))
            guard !Task.isCancelled else { return }
            // In glance mode, just disconnect silently — no prompt
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
