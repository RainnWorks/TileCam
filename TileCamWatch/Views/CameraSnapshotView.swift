import SwiftUI

/// Auto-timeout after 10 minutes of streaming to save battery.
private let streamTimeoutSeconds: TimeInterval = 600

/// Frame staleness threshold — show warning after 5 seconds with no new frame.
private let frameStalenessThreshold: TimeInterval = 5

struct CameraSnapshotView: View {
    let streamName: String
    let initialZoom: CGFloat
    let initialCenterX: CGFloat
    let initialCenterY: CGFloat

    @EnvironmentObject var session: WatchSessionManager

    @State private var zoom: CGFloat = 1.0
    @State private var centerX: CGFloat = 0.5
    @State private var centerY: CGFloat = 0.5
    @State private var dragStart: CGSize = .zero
    @State private var selectedMode: StreamMode = .videoAndAudio
    @State private var viewportDebounce: Task<Void, Never>?

    /// Fix #7: Auto-timeout
    @State private var timeoutTask: Task<Void, Never>?
    @State private var showTimeoutPrompt = false

    /// Fix #2: Frame staleness detection
    @State private var isFrameStale = false
    @State private var stalenessTimer: Task<Void, Never>?

    /// Fix #6: Camera switching sheet
    @State private var showCameraPicker = false

    /// Fix #8: Track the source image aspect ratio for correct pan mapping
    @State private var sourceAspect: CGFloat = 16.0 / 9.0

    private let maxZoom: CGFloat = 6.0
    private let minZoom: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if selectedMode != .audioOnly {
                    videoContent(in: geo.size)
                } else {
                    audioOnlyView
                }

                // Fix #2: Staleness overlay
                if isFrameStale && session.latestSnapshot != nil && !session.isStreamPaused {
                    stalenessOverlay
                }

                // Fix #3: Stream paused overlay
                if session.isStreamPaused {
                    pausedOverlay
                }

                // Fix #7: Timeout prompt
                if showTimeoutPrompt {
                    timeoutPromptOverlay
                }
            }
        }
        .navigationTitle(streamName.replacingOccurrences(of: "_", with: " "))
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
            // Fix #2: Reset staleness on new frame
            isFrameStale = false
            resetStalenessTimer()
            // Fix #7: Reset timeout on activity
            resetTimeout()
        }
        .onChange(of: session.latestSnapshot) { _, newImage in
            // Fix #8: Track source aspect ratio
            if let img = newImage {
                let w = img.size.width
                let h = img.size.height
                if h > 0 { sourceAspect = w / h }
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 8) {
                    modePicker

                    // Fix #6: Camera switch button
                    if session.availableStreams.count > 1 {
                        Button {
                            showCameraPicker = true
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if zoom > 1.01 {
                        Text(String(format: "%.1fx", zoom))
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .sheet(isPresented: $showCameraPicker) {
            cameraPicker
        }
        .onAppear {
            zoom = max(initialZoom, 1.0)
            centerX = initialCenterX
            centerY = initialCenterY
            dragStart = CGSize(width: centerX, height: centerY)
            session.subscribe(
                to: streamName, mode: selectedMode,
                zoom: zoom, centerX: centerX, centerY: centerY
            )
            resetTimeout()
            resetStalenessTimer()
        }
        .onDisappear {
            viewportDebounce?.cancel()
            timeoutTask?.cancel()
            stalenessTimer?.cancel()
            session.unsubscribe()
        }
    }

    // MARK: - Video

    @ViewBuilder
    private func videoContent(in size: CGSize) -> some View {
        if let image = session.latestSnapshot {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .gesture(dragGesture(in: size))
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text(session.isSubscribing ? "Connecting..." : "Waiting for frames...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if session.audioPlayer.isPlaying {
            VStack {
                Spacer()
                HStack {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
        }
    }

    // MARK: - Audio Only

    private var audioOnlyView: some View {
        VStack(spacing: 12) {
            Image(systemName: session.audioPlayer.isPlaying ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 40))
                .foregroundStyle(session.audioPlayer.isPlaying ? .green : .secondary)
                .symbolEffect(.pulse, isActive: session.audioPlayer.isPlaying)

            Text(streamName.replacingOccurrences(of: "_", with: " "))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(session.audioPlayer.isPlaying ? "Listening..." : "Connecting...")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Overlays

    /// Fix #2: Frame staleness warning
    private var stalenessOverlay: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                    Text("Stale")
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

    /// Fix #3: Stream paused overlay
    private var pausedOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "pause.circle")
                .font(.title3)
                .foregroundStyle(.orange.opacity(0.8))
            Text("iPhone\nbackgrounded")
                .font(.system(size: 10).weight(.medium))
                .foregroundStyle(.orange.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    /// Fix #7: Timeout prompt
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

    // MARK: - Mode Picker

    private var modePicker: some View {
        HStack(spacing: 12) {
            ForEach(StreamMode.allCases) { mode in
                Button {
                    selectedMode = mode
                    session.changeMode(mode)
                } label: {
                    Image(systemName: mode.icon)
                        .font(.caption)
                        .foregroundStyle(selectedMode == mode ? .white : .secondary)
                }
            }
        }
    }

    // MARK: - Camera Picker (Fix #6)

    private var cameraPicker: some View {
        NavigationStack {
            List(session.availableStreams.filter { $0 != streamName }, id: \.self) { name in
                Button {
                    showCameraPicker = false
                    // Switch to new camera by unsubscribing and re-subscribing
                    session.unsubscribe()
                    session.subscribe(to: name, mode: selectedMode)
                    // Reset viewport for new camera
                    zoom = 1.0
                    centerX = 0.5
                    centerY = 0.5
                    dragStart = .zero
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "video.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(name.replacingOccurrences(of: "_", with: " "))
                            .font(.body)
                    }
                }
            }
            .listStyle(.carousel)
            .navigationTitle("Switch Camera")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Gestures (Fix #8: aspect ratio correction)

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1.0 else { return }
                // Fix #8: Use source aspect ratio to compute the actual displayed image size
                let viewAspect = size.width / size.height
                let displayW: CGFloat
                let displayH: CGFloat
                if sourceAspect > viewAspect {
                    // Letterboxed (pillarboxed) — image fills width
                    displayW = size.width
                    displayH = size.width / sourceAspect
                } else {
                    // Image fills height
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

    /// Fix #7: Reset the auto-timeout countdown.
    private func resetTimeout() {
        timeoutTask?.cancel()
        showTimeoutPrompt = false
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(streamTimeoutSeconds))
            guard !Task.isCancelled else { return }
            showTimeoutPrompt = true
            // If user doesn't respond within 60 seconds, auto-disconnect
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, showTimeoutPrompt else { return }
            session.unsubscribe()
        }
    }

    /// Fix #2: Reset the staleness detection timer.
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
