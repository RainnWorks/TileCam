import SwiftUI

struct CameraSnapshotView: View {
    let streamName: String
    @EnvironmentObject var session: WatchSessionManager

    @State private var zoom: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    private let maxZoom: CGFloat = 6.0
    private let minZoom: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = session.latestSnapshot {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .offset(panOffset)
                        .gesture(dragGesture(in: geo.size))
                        .animation(.interactiveSpring, value: panOffset)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Connecting...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
        .onAppear {
            session.subscribe(to: streamName)
        }
        .onDisappear {
            session.unsubscribe()
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
