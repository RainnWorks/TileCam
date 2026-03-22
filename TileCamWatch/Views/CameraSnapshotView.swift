import SwiftUI

struct CameraSnapshotView: View {
    let streamName: String
    @EnvironmentObject var session: WatchSessionManager

    @State private var zoom: CGFloat = 1.0
    @State private var panCenter: CGSize = .zero // normalized offset from center (-0.5...0.5)
    @State private var lastPanCenter: CGSize = .zero
    @State private var selectedMode: StreamMode = .videoAndAudio
    @State private var viewportDebounce: Task<Void, Never>?

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
                panCenter = .zero
                lastPanCenter = .zero
            }
            sendViewportUpdate()
        }
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
            // Image is displayed 1:1 — iPhone sends pre-cropped frames
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
                // Convert screen-space drag to normalized pan offset
                // Dragging right reveals content to the left, so negate
                let dx = -value.translation.width / (size.width * zoom)
                let dy = -value.translation.height / (size.height * zoom)
                panCenter = CGSize(
                    width: clampCenter(lastPanCenter.width + dx),
                    height: clampCenter(lastPanCenter.height + dy)
                )
                sendViewportUpdate()
            }
            .onEnded { _ in
                lastPanCenter = panCenter
            }
    }

    /// Clamp normalized pan offset so the crop stays within the image
    private func clampCenter(_ value: CGFloat) -> CGFloat {
        let maxOffset = max(0, (1.0 - 1.0 / zoom) / 2.0)
        return min(max(value, -maxOffset), maxOffset)
    }

    // MARK: - Viewport

    private func sendViewportUpdate() {
        viewportDebounce?.cancel()
        viewportDebounce = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            session.sendViewport(
                zoom: zoom,
                centerX: 0.5 + panCenter.width,
                centerY: 0.5 + panCenter.height
            )
        }
    }
}
