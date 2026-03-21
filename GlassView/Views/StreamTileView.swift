import SwiftUI
import WebRTC
import os

private let log = Logger(subsystem: "works.rainn.tilecam", category: "StreamTile")

private struct ShowUIKey: EnvironmentKey {
    static let defaultValue = true
}

private struct ToggleUIKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var showUI: Bool {
        get { self[ShowUIKey.self] }
        set { self[ShowUIKey.self] = newValue }
    }
    var toggleUI: () -> Void {
        get { self[ToggleUIKey.self] }
        set { self[ToggleUIKey.self] = newValue }
    }
}

struct StreamTileView: View {
    let stream: Stream
    let service: Go2RTCService
    @EnvironmentObject var appState: AppState
    @Environment(\.showUI) private var showUI
    @Environment(\.toggleUI) private var toggleUI
    @StateObject private var client: WebRTCClient

    @State private var transform: CGAffineTransform
    @State private var lastTransform: CGAffineTransform
    @State private var contentSize: CGSize = .zero

    init(stream: Stream, service: Go2RTCService) {
        self.stream = stream
        self.service = service
        _client = StateObject(wrappedValue: WebRTCClient(service: service, streamName: stream.name))

        let state = LayoutStore.loadViewState(for: stream.name)
        let t = CGAffineTransform(translationX: state.panX, y: state.panY)
            .scaledBy(x: max(state.zoom, 1.0), y: max(state.zoom, 1.0))
        _transform = State(initialValue: state.zoom <= 1.0 ? .identity : t)
        _lastTransform = State(initialValue: state.zoom <= 1.0 ? .identity : t)
    }

    var body: some View {
        ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture { toggleUI() }

            if let videoTrack = client.videoTrack {
                WebRTCVideoView(videoTrack: videoTrack)
                    .background(alignment: .topLeading) {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { contentSize = proxy.size }
                                .onChange(of: proxy.size) { _, newSize in
                                    contentSize = newSize
                                }
                        }
                    }
                    .scaleEffect(
                        x: transform.scaleX,
                        y: transform.scaleY,
                        anchor: .zero
                    )
                    .offset(x: transform.tx, y: transform.ty)
                    .gesture(
                        SimultaneousGesture(magnifyGesture, dragGesture)
                    )
                    .gesture(doubleTapGesture)
            }

            // Status overlays
            switch client.connectionState {
            case .connected, .completed:
                EmptyView()
            case .failed:
                failedOverlay
            case .disconnected:
                statusCenter(icon: "wifi.slash", label: "Lost", color: .orange)
            case .new, .checking:
                connectingOverlay
            case .closed:
                statusCenter(icon: "xmark.circle", label: "Closed", color: .secondary)
            @unknown default:
                EmptyView()
            }

            // Bottom bar
            if showUI {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Text(stream.name.replacingOccurrences(of: "_", with: " "))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.4), in: Capsule())

                        Circle()
                            .fill(stateColor)
                            .frame(width: 6, height: 6)

                        if client.isRetrying {
                            HStack(spacing: 3) {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.5)
                                Text("\(client.retryCount)")
                                    .font(.system(size: 9).monospaced())
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.4), in: Capsule())
                        }

                        Spacer()

                        if transform.scaleX > 1.01 {
                            Text("\(transform.scaleX, specifier: "%.1f")x")
                                .font(.system(size: 9).monospaced())
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.4), in: Capsule())
                        }
                    }
                    .padding(6)
                }
                .transition(.opacity)
            }
        }
        .clipped()
        .task {
            await client.connect()
        }
        .onDisappear {
            client.disconnect()
        }
    }

    // MARK: - Gestures

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .onChanged { value in
                let anchor = CGPoint(
                    x: value.startAnchor.x * contentSize.width,
                    y: value.startAnchor.y * contentSize.height
                )
                let scaleTransform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                    .scaledBy(x: value.magnification, y: value.magnification)
                    .translatedBy(x: -anchor.x, y: -anchor.y)

                withAnimation(.interactiveSpring) {
                    transform = lastTransform.concatenating(scaleTransform)
                }
            }
            .onEnded { _ in
                onEndGesture()
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                var t = lastTransform
                t.tx += value.translation.width
                t.ty += value.translation.height
                transform = t
            }
            .onEnded { _ in
                onEndGesture()
            }
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                let newTransform: CGAffineTransform
                if transform.isIdentity {
                    let anchor = value.location
                    newTransform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                        .scaledBy(x: 3, y: 3)
                        .translatedBy(x: -anchor.x, y: -anchor.y)
                } else {
                    newTransform = .identity
                }
                withAnimation(.linear(duration: 0.15)) {
                    transform = newTransform
                    lastTransform = newTransform
                }
                persistState()
            }
    }

    private func onEndGesture() {
        let capped = limitTransform(transform)
        if capped == transform {
            lastTransform = transform
        } else {
            withAnimation(.snappy(duration: 0.2)) {
                transform = capped
                lastTransform = capped
            }
        }
        persistState()
    }

    private func limitTransform(_ t: CGAffineTransform) -> CGAffineTransform {
        let scaleX = t.scaleX
        let scaleY = t.scaleY

        if scaleX < 1.0 || scaleY < 1.0 {
            return .identity
        }

        var capped = t

        let currentScale = max(scaleX, scaleY)
        if currentScale > 20.0 {
            let factor = 20.0 / currentScale
            let center = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
            let capT = CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: factor, y: factor)
                .translatedBy(x: -center.x, y: -center.y)
            capped = capped.concatenating(capT)
        }

        let maxX = contentSize.width * (capped.scaleX - 1)
        let maxY = contentSize.height * (capped.scaleY - 1)
        capped.tx = min(max(capped.tx, -maxX), 0)
        capped.ty = min(max(capped.ty, -maxY), 0)

        return capped
    }

    private func persistState() {
        let state = StreamViewState(
            zoom: Double(transform.scaleX),
            panX: Double(transform.tx),
            panY: Double(transform.ty)
        )
        LayoutStore.saveViewState(state, for: stream.name)
    }

    // MARK: - Status

    private var stateColor: Color {
        switch client.connectionState {
        case .connected, .completed: .green
        case .checking, .new: .yellow
        case .failed: .red
        case .disconnected: .orange
        default: .secondary
        }
    }

    private var connectingOverlay: some View {
        ProgressView()
            .tint(.white.opacity(0.6))
            .scaleEffect(0.8)
    }

    private var failedOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.red.opacity(0.8))

            if !client.isRetrying {
                Button {
                    Task { await client.connect() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                .liquidGlassCircle()
            }
        }
    }

    private func statusCenter(icon: String, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color.opacity(0.8))
            Text(label)
                .font(.system(size: 10).weight(.medium))
                .foregroundStyle(color.opacity(0.6))
        }
    }
}

// MARK: - WebRTC Video

struct WebRTCVideoView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        view.clipsToBounds = true
        videoTrack.add(view)
        context.coordinator.currentTrack = videoTrack
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // Only re-add if the track actually changed
        if context.coordinator.currentTrack !== videoTrack {
            context.coordinator.currentTrack?.remove(uiView)
            videoTrack.add(uiView)
            context.coordinator.currentTrack = videoTrack
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.currentTrack?.remove(uiView)
        coordinator.currentTrack = nil
    }

    final class Coordinator {
        var currentTrack: RTCVideoTrack?
    }
}

// MARK: - CGAffineTransform helpers

extension CGAffineTransform {
    var scaleX: CGFloat {
        sqrt(a * a + c * c)
    }

    var scaleY: CGFloat {
        sqrt(b * b + d * d)
    }
}
