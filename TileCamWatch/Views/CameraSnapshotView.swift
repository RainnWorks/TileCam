import SwiftUI

struct CameraSnapshotView: View {
    let streamName: String
    @EnvironmentObject var session: WatchSessionManager

    @State private var zoom: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var selectedMode: StreamMode = .videoAndAudio

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
            if newZoom <= 1.0 {
                withAnimation(.smooth(duration: 0.2)) {
                    panOffset = .zero
                    lastPanOffset = .zero
                }
            } else {
                clampPan()
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                modePicker
            }
        }
        .onAppear {
            session.subscribe(to: streamName, mode: selectedMode)
        }
        .onDisappear {
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
                .scaleEffect(zoom)
                .offset(panOffset)
                .gesture(dragGesture(in: size))
                .animation(.interactiveSpring, value: panOffset)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                Text("Connecting...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        // Audio indicator when playing audio+video
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
                panOffset = CGSize(
                    width: lastPanOffset.width + value.translation.width,
                    height: lastPanOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                clampPan()
                lastPanOffset = panOffset
            }
    }

    private func clampPan() {
        let maxPanX = max(0, (zoom - 1) * 100)
        let maxPanY = max(0, (zoom - 1) * 60)
        withAnimation(.smooth(duration: 0.15)) {
            panOffset = CGSize(
                width: min(max(panOffset.width, -maxPanX), maxPanX),
                height: min(max(panOffset.height, -maxPanY), maxPanY)
            )
        }
    }
}
