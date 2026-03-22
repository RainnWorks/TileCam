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

private struct RootSafeAreaKey: EnvironmentKey {
    static let defaultValue: EdgeInsets = EdgeInsets()
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
    var rootSafeArea: EdgeInsets {
        get { self[RootSafeAreaKey.self] }
        set { self[RootSafeAreaKey.self] = newValue }
    }
}

struct StreamTileView: View {
    let stream: Stream
    let service: Go2RTCService
    @EnvironmentObject var appState: AppState
    @Environment(\.showUI) private var showUI
    @Environment(\.toggleUI) private var toggleUI
    @Environment(\.rootSafeArea) private var rootSafeArea
    @StateObject private var client: WebRTCClient

    @State private var transform: CGAffineTransform
    @State private var lastTransform: CGAffineTransform
    @State private var contentSize: CGSize = .zero
    @State private var showRecoveryFlash = false
    @State private var wasDisconnected = false

    private let zoomHaptic = UIImpactFeedbackGenerator(style: .medium)

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

            videoLayer
            statusOverlay
            recoveryFlashBorder
            audioIndicator

            if showUI {
                bottomBar
            }
        }
        .clipped()
        .onLongPressGesture(minimumDuration: 0.4) {
            withAnimation(.smooth(duration: 0.2)) {
                appState.toggleStreamMute(stream.name)
            }
            zoomHaptic.impactOccurred()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stream: \(stream.name.replacingOccurrences(of: "_", with: " "))")
        .accessibilityValue(isStreamAudible ? "Audio on" : "Audio muted")
        .animation(.smooth(duration: 0.4), value: client.videoTrack != nil)
        .animation(.smooth(duration: 0.25), value: isStreamAudible)
        .onChange(of: client.connectionState) { _, newState in
            if newState == .failed || newState == .disconnected {
                wasDisconnected = true
            } else if (newState == .connected || newState == .completed) && wasDisconnected {
                wasDisconnected = false
                showRecoveryFlash = true
                Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    withAnimation { showRecoveryFlash = false }
                }
            }
        }
        .onChange(of: appState.isGlobalAudioEnabled) { _, _ in syncAudioState() }
        .onChange(of: appState.mutedStreamNames) { _, _ in syncAudioState() }
        .onChange(of: client.audioTrack) { _, _ in syncAudioState() }
        .task {
            await client.connect()
        }
        .onDisappear {
            client.disconnect()
        }
    }

    // MARK: - View Layers

    @ViewBuilder
    private var videoLayer: some View {
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
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.02)),
                        removal: .opacity
                    )
                )
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch client.connectionState {
        case .connected, .completed:
            EmptyView()
        case .failed:
            failedOverlay
        case .disconnected:
            statusCenter(icon: "wifi.slash", label: "Disconnected", color: .orange)
        case .new, .checking:
            connectingOverlay
                .transition(.opacity)
        case .closed:
            statusCenter(icon: "xmark.circle", label: "Stream ended", color: .secondary)
        @unknown default:
            EmptyView()
        }
    }

    private var recoveryFlashBorder: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.green.opacity(showRecoveryFlash ? 0.5 : 0), lineWidth: 1.5)
            .animation(.smooth(duration: 0.6), value: showRecoveryFlash)
    }

    @ViewBuilder
    private var audioIndicator: some View {
        if client.audioTrack != nil {
            AudioWaveformIndicator(
                level: client.audioLevel,
                isMuted: !appState.isStreamAudioEnabled(stream.name)
            )
            .padding(.top, max(8, rootSafeArea.top + 4))
            .padding(.leading, max(8, rootSafeArea.leading + 4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private var bottomBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Text(stream.name.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.4), in: Capsule())

                stateIcon
                    .animation(.smooth(duration: 0.5), value: client.connectionState)

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
                    let zoomText = String(format: "%.1fx", transform.scaleX)
                    Text(zoomText)
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.white.opacity(0.5))
                        .contentTransition(.numericText())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.4), in: Capsule())
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .scale(scale: 1.1).combined(with: .opacity)
                            )
                        )
                        .animation(.smooth(duration: 0.2), value: zoomText)
                }
            }
            .padding(6)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stream.name.replacingOccurrences(of: "_", with: " ")), \(stateLabel)")
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
                let currentScale = transform.scaleX
                let newTransform: CGAffineTransform
                let anchor = value.location

                if currentScale < 1.5 {
                    // 1x → 2x
                    newTransform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                        .scaledBy(x: 2, y: 2)
                        .translatedBy(x: -anchor.x, y: -anchor.y)
                } else if currentScale < 3.0 {
                    // 2x → 4x
                    newTransform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                        .scaledBy(x: 4, y: 4)
                        .translatedBy(x: -anchor.x, y: -anchor.y)
                } else {
                    // 4x+ → reset
                    newTransform = .identity
                }

                zoomHaptic.impactOccurred()
                withAnimation(.smooth(duration: 0.25)) {
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

    // MARK: - Audio

    private var isStreamAudible: Bool {
        appState.isStreamAudioEnabled(stream.name) && client.audioTrack != nil
    }

    private func syncAudioState() {
        client.isAudioEnabled = appState.isStreamAudioEnabled(stream.name)
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

    private var stateLabel: String {
        switch client.connectionState {
        case .connected, .completed: "Connected"
        case .checking, .new: "Connecting"
        case .failed: "Connection failed"
        case .disconnected: "Disconnected"
        case .closed: "Stream ended"
        default: "Unknown"
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch client.connectionState {
        case .connected, .completed:
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .shadow(color: .green.opacity(0.6), radius: 4)
        case .checking, .new:
            Image(systemName: "circle.dotted")
                .font(.system(size: 8))
                .foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.red)
        case .disconnected:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
        default:
            Circle()
                .fill(.secondary)
                .frame(width: 6, height: 6)
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
                .accessibilityLabel("Retry connection")
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
