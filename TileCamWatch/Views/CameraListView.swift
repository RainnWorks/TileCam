import SwiftUI

/// Navigation value that carries the stream name + optional initial viewport.
struct CameraDestination: Hashable {
    let streamName: String
    var zoom: CGFloat = 1.0
    var centerX: CGFloat = 0.5
    var centerY: CGFloat = 0.5
}

struct CameraListView: View {
    @EnvironmentObject var session: WatchSessionManager
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if !session.isPhoneReachable {
                    notReachableView
                } else if session.availableStreams.isEmpty {
                    noStreamsView
                } else {
                    streamList
                }
            }
            .navigationTitle("TileCam")
            .navigationDestination(for: CameraDestination.self) { dest in
                CameraSnapshotView(
                    streamName: dest.streamName,
                    initialZoom: dest.zoom,
                    initialCenterX: dest.centerX,
                    initialCenterY: dest.centerY
                )
                .environmentObject(session)
            }
            .onChange(of: session.pushedCamera) { _, pushed in
                guard let pushed else { return }
                // Fix #4: Pop to root first to prevent double-push / stacked dead views
                if !navigationPath.isEmpty {
                    navigationPath = NavigationPath()
                    // Delay to let the pop animate before pushing
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        navigationPath.append(CameraDestination(
                            streamName: pushed.streamName,
                            zoom: pushed.zoom,
                            centerX: pushed.centerX,
                            centerY: pushed.centerY
                        ))
                    }
                } else {
                    navigationPath.append(CameraDestination(
                        streamName: pushed.streamName,
                        zoom: pushed.zoom,
                        centerX: pushed.centerX,
                        centerY: pushed.centerY
                    ))
                }
                session.pushedCamera = nil
            }
        }
    }

    private var streamList: some View {
        List(session.availableStreams, id: \.self) { name in
            NavigationLink(value: CameraDestination(streamName: name)) {
                HStack(spacing: 10) {
                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(name.replacingOccurrences(of: "_", with: " "))
                        .font(.body)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.carousel)
    }

    private var notReachableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.slash")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Reconnecting to\niPhone...")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var noStreamsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("No cameras\navailable")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
