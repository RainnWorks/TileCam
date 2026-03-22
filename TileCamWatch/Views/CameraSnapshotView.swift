import SwiftUI

struct CameraSnapshotView: View {
    let streamName: String
    @EnvironmentObject var session: WatchSessionManager

    /// Local viewport state — mirrors iPhone, can be overridden by Watch gestures.
    @State private var zoom: CGFloat = 1.0
    @State private var centerX: CGFloat = 0.5
    @State private var centerY: CGFloat = 0.5
    @State private var dragStart: CGSize = .zero
    @State private var selectedMode: StreamMode = .videoAndAudio
    @State private var viewportDebounce: Task<Void, Never>?
    @State private var suppressSync = false

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
            }
            sendViewportToiPhone()
        }
        // Receive viewport syncs from iPhone
        .onChange(of: session.syncedZoom) { _, _ in applyiPhoneViewport() }
        .onChange(of: session.syncedCenterX) { _, _ in applyiPhoneViewport() }
        .onChange(of: session.syncedCenterY) { _, _ in applyiPhoneViewport() }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 8) {
                    modePicker
                    if zoom > 1.01 {
                        Text(String(format: "%.1fx", zoom))
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .onAppear {
            // Start with iPhone's current viewport
            zoom = max(session.syncedZoom, 1.0)
            centerX = session.syncedCenterX
            centerY = session.syncedCenterY
            session.subscribe(to: streamName, mode: selectedMode)
        }
        .onDisappear {
            viewportDebounce?.cancel()
            session.unsubscribe()
        }
    }

    // MARK: - Video

    @ViewBuilder
    private func videoContent(in size: CGSize) -> some View {
        if let image = session.latestSnapshot {
            // Frames are pre-cropped by iPhone — display 1:1
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .gesture(dragGesture(in: size))
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Connecting...")
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

    // MARK: - Gestures

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1.0 else { return }
                // Convert screen-space drag to normalized viewport shift
                let dx = -value.translation.width / (size.width * zoom)
                let dy = -value.translation.height / (size.height * zoom)
                let maxOffset = max(0, (1.0 - 1.0 / zoom) / 2.0)
                centerX = min(max(dragStart.width + dx, 0.5 - maxOffset), 0.5 + maxOffset)
                centerY = min(max(dragStart.height + dy, 0.5 - maxOffset), 0.5 + maxOffset)
                sendViewportToiPhone()
            }
            .onEnded { _ in
                dragStart = CGSize(width: centerX, height: centerY)
            }
    }

    // MARK: - Viewport Sync

    /// Send the Watch's current viewport to the iPhone for cropping.
    private func sendViewportToiPhone() {
        guard !suppressSync else { return }
        viewportDebounce?.cancel()
        viewportDebounce = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            session.sendViewport(zoom: zoom, centerX: centerX, centerY: centerY)
        }
    }

    /// Apply a viewport update received from the iPhone.
    private func applyiPhoneViewport() {
        guard !suppressSync else { return }
        suppressSync = true
        zoom = max(session.syncedZoom, 1.0)
        centerX = session.syncedCenterX
        centerY = session.syncedCenterY
        dragStart = CGSize(width: centerX, height: centerY)

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            suppressSync = false
        }
    }
}
