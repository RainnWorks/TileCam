import SwiftUI

/// Frame staleness threshold — show warning after 5 seconds with no new frame.
private let frameStalenessThreshold: TimeInterval = 5

/// Auto-hide delay for tap-to-reveal controls.
private let controlsFadeDelay: TimeInterval = 4

struct CameraSnapshotView: View {
    let initialStreamName: String
    let initialZoom: CGFloat
    let initialCenterX: CGFloat
    let initialCenterY: CGFloat

    @EnvironmentObject var session: WatchSessionManager
    @ObservedObject var settings = WatchSettings.shared

    /// Mutable stream name — updates when switching cameras in-place.
    @State private var activeStreamName: String = ""

    @State private var zoom: CGFloat = 1.0
    @State private var centerX: CGFloat = 0.5
    @State private var centerY: CGFloat = 0.5
    @State private var dragStart: CGSize = .zero
    @State private var selectedMode: StreamMode = .videoAndAudio
    @State private var viewportDebounce: Task<Void, Never>?

    /// Tap-to-show/hide controls (matches iPhone pattern)
    @State private var showControls = true
    @State private var controlsHideTask: Task<Void, Never>?

    /// Auto-timeout
    @State private var timeoutTask: Task<Void, Never>?
    @State private var showTimeoutPrompt = false

    /// Frame staleness detection
    @State private var isFrameStale = false
    @State private var stalenessTimer: Task<Void, Never>?

    /// Camera switching sheet
    @State private var showCameraPicker = false

    /// Track source image aspect ratio for correct pan mapping
    @State private var sourceAspect: CGFloat = 16.0 / 9.0

    private let maxZoom: CGFloat = 6.0
    private let minZoom: CGFloat = 1.0

    // MARK: - Init adapter

    init(streamName: String, initialZoom: CGFloat = 1.0, initialCenterX: CGFloat = 0.5, initialCenterY: CGFloat = 0.5) {
        self.initialStreamName = streamName
        self.initialZoom = initialZoom
        self.initialCenterX = initialCenterX
        self.initialCenterY = initialCenterY
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if selectedMode != .audioOnly {
                    videoContent(in: geo.size)
                } else {
                    audioOnlyView
                }

                // Overlays — priority: timeout > paused > stale
                overlayStack
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }
        }
        .navigationTitle(activeStreamName.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.inline)
        .focusable()
        .digitalCrownRotation(
            $zoom,
            from: minZoom,
            through: maxZoom,
            by: 0.15,
            sensitivity: .medium
        )
        .onChange(of: zoom) { _, newZoom in
            if newZoom <= 1.01 {
                centerX = 0.5
                centerY = 0.5
                dragStart = .zero
            }
            sendViewport()
        }
        .onChange(of: session.lastFrameTime) { _, _ in
            isFrameStale = false
            resetStalenessTimer()
            resetTimeout()
        }
        .onChange(of: session.latestSnapshot) { _, newImage in
            if let img = newImage {
                let w = img.size.width
                let h = img.size.height
                if h > 0 { sourceAspect = w / h }
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                if showControls {
                    toolbarContent
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .sheet(isPresented: $showCameraPicker) {
            cameraPicker
        }
        .onAppear {
            // Stop extended runtime session — we're back in the foreground
            ExtendedRuntimeManager.shared.stop()

            activeStreamName = initialStreamName
            selectedMode = settings.resolvedMode
            zoom = max(initialZoom, 1.0)
            centerX = initialCenterX
            centerY = initialCenterY
            dragStart = CGSize(width: centerX, height: centerY)

            // If already subscribed (wrist-raise after audio-only/always-on), restore mode
            if session.subscribedStream == activeStreamName {
                if session.currentMode != selectedMode {
                    session.changeMode(selectedMode)
                }
            } else {
                session.subscribe(
                    to: activeStreamName, mode: selectedMode,
                    zoom: zoom, centerX: centerX, centerY: centerY
                )
            }
            resetTimeout()
            resetStalenessTimer()
            scheduleAutoHide()
        }
        .onDisappear {
            viewportDebounce?.cancel()
            controlsHideTask?.cancel()

            // Respect wrist-down behavior setting
            if settings.keepAudioOnWristDown && !settings.keepVideoOnWristDown {
                // Audio-only: cancel timeout (passive listening shouldn't be interrupted)
                timeoutTask?.cancel()
                stalenessTimer?.cancel()
                if session.currentMode != .audioOnly {
                    session.changeMode(.audioOnly)
                }
                ExtendedRuntimeManager.shared.startIfNeeded()
            } else if settings.keepVideoOnWristDown {
                // Always-on: cancel timeout, keep everything running
                timeoutTask?.cancel()
                stalenessTimer?.cancel()
                ExtendedRuntimeManager.shared.startIfNeeded()
            } else {
                // Eco: stop everything
                timeoutTask?.cancel()
                stalenessTimer?.cancel()
                ExtendedRuntimeManager.shared.stop()
                session.unsubscribe()
            }
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

    // MARK: - Video

    @ViewBuilder
    private func videoContent(in size: CGSize) -> some View {
        if let image = session.latestSnapshot {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .opacity(session.isStreamPaused ? 0.4 : (isFrameStale ? 0.7 : 1.0))
                .animation(.easeInOut(duration: 0.4), value: session.isStreamPaused)
                .animation(.easeInOut(duration: 0.4), value: isFrameStale)
                .gesture(dragGesture(in: size))
        } else {
            connectingView
        }

        // Audio indicator
        if session.audioPlayer.isPlaying && selectedMode != .audioOnly && !showControls {
            VStack {
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "waveform")
                        .font(.system(size: 8))
                    Text("Audio")
                        .font(.system(size: 8))
                }
                .foregroundStyle(.green.opacity(0.6))
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.opacity)
        }
    }

    private var connectingView: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.2))
                .symbolEffect(.pulse, isActive: session.isSubscribing)

            Text(session.isSubscribing
                 ? "Connecting..."
                 : "Waiting for \(activeStreamName.replacingOccurrences(of: "_", with: " "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Audio Only

    private var audioOnlyView: some View {
        VStack(spacing: 12) {
            Image(systemName: session.audioPlayer.isPlaying ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 40))
                .foregroundStyle(session.audioPlayer.isPlaying ? .green : .secondary)
                .symbolEffect(.pulse, isActive: session.audioPlayer.isPlaying)

            Text(session.audioPlayer.isPlaying ? "Listening..." : "Connecting...")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Overlay Stack

    @ViewBuilder
    private var overlayStack: some View {
        if showTimeoutPrompt {
            timeoutPromptOverlay
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else if session.isStreamPaused {
            pausedOverlay
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else if isFrameStale && session.latestSnapshot != nil {
            frozenBadge
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    private var frozenBadge: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 3) {
                    Circle().fill(.yellow).frame(width: 5, height: 5)
                    Text("Frozen")
                        .font(.system(size: 9).weight(.medium))
                }
                .foregroundStyle(.yellow)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            Spacer()
        }
    }

    private var pausedOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "pause.circle")
                .font(.title3)
                .foregroundStyle(.orange.opacity(0.8))
            Text("iPhone in background")
                .font(.system(size: 10).weight(.medium))
                .foregroundStyle(.orange.opacity(0.6))
        }
    }

    private var timeoutPromptOverlay: some View {
        VStack(spacing: 8) {
            Text("Still watching?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            Button {
                showTimeoutPrompt = false
                resetTimeout()
            } label: {
                Text("Keep Streaming")
                    .font(.caption2.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Toolbar

    private var toolbarContent: some View {
        HStack(spacing: 10) {
            // Mode cycle
            Button {
                cycleMode()
                scheduleAutoHide()
            } label: {
                Image(systemName: selectedMode.icon)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
            }

            // Camera switch
            if session.availableStreams.count > 1 {
                Button {
                    showCameraPicker = true
                    scheduleAutoHide()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Glance mode toggle
            Button {
                settings.glanceModeEnabled = true
            } label: {
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Zoom indicator
            if zoom > 1.01 {
                Text(String(format: "%.1fx", zoom))
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Mode Cycling

    private func cycleMode() {
        let allModes = StreamMode.allCases
        guard let currentIndex = allModes.firstIndex(of: selectedMode) else { return }
        let nextIndex = (currentIndex + 1) % allModes.count
        selectedMode = allModes[nextIndex]
        session.changeMode(selectedMode)
    }

    // MARK: - Camera Picker

    private var cameraPicker: some View {
        NavigationStack {
            List(session.availableStreams, id: \.self) { name in
                Button {
                    showCameraPicker = false
                    switchToCamera(name)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "video.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(name.replacingOccurrences(of: "_", with: " "))
                            .font(.body)
                        if name == activeStreamName {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .listStyle(.carousel)
            .navigationTitle("Switch Camera")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func switchToCamera(_ name: String) {
        guard name != activeStreamName else { return }
        session.unsubscribe()
        activeStreamName = name
        zoom = 1.0
        centerX = 0.5
        centerY = 0.5
        dragStart = .zero
        isFrameStale = false
        session.subscribe(to: name, mode: selectedMode)
        resetTimeout()
        resetStalenessTimer()
    }

    // MARK: - Gestures

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1.0 else { return }
                let viewAspect = size.width / size.height
                let displayW: CGFloat
                let displayH: CGFloat
                if sourceAspect > viewAspect {
                    displayW = size.width
                    displayH = size.width / sourceAspect
                } else {
                    displayH = size.height
                    displayW = size.height * sourceAspect
                }

                let dx = -value.translation.width / (displayW * zoom)
                let dy = -value.translation.height / (displayH * zoom)
                let maxOffset = max(0, (1.0 - 1.0 / zoom) / 2.0)
                centerX = min(max(dragStart.width + dx, 0.5 - maxOffset), 0.5 + maxOffset)
                centerY = min(max(dragStart.height + dy, 0.5 - maxOffset), 0.5 + maxOffset)
                sendViewport()
            }
            .onEnded { _ in
                dragStart = CGSize(width: centerX, height: centerY)
            }
    }

    // MARK: - Viewport

    private func sendViewport() {
        viewportDebounce?.cancel()
        viewportDebounce = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            session.sendViewport(zoom: zoom, centerX: centerX, centerY: centerY)
        }
    }

    // MARK: - Timers

    private func resetTimeout() {
        timeoutTask?.cancel()
        showTimeoutPrompt = false
        guard settings.hasTimeout else { return }
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(settings.timeoutSeconds))
            guard !Task.isCancelled else { return }
            showTimeoutPrompt = true
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, showTimeoutPrompt else { return }
            session.unsubscribe()
        }
    }

    private func resetStalenessTimer() {
        stalenessTimer?.cancel()
        isFrameStale = false
        stalenessTimer = Task {
            try? await Task.sleep(for: .seconds(frameStalenessThreshold))
            guard !Task.isCancelled else { return }
            if session.subscribedStream != nil && !session.isStreamPaused {
                isFrameStale = true
            }
        }
    }
}
