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
    @ObservedObject var settings = WatchSettings.shared
    @State private var navigationPath = NavigationPath()
    @State private var showSettings = false

    var body: some View {
        standardNavigation
    }

    private var standardNavigation: some View {
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
                if !navigationPath.isEmpty {
                    navigationPath = NavigationPath()
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchSettingsView()
                            .environmentObject(session)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var streamList: some View {
        List {
            if !session.phoneActiveStreams.isEmpty {
                Section("On iPhone") {
                    ForEach(session.phoneActiveStreams) { active in
                        NavigationLink(value: CameraDestination(
                            streamName: active.name,
                            zoom: active.zoom,
                            centerX: active.centerX,
                            centerY: active.centerY
                        )) {
                            HStack(spacing: 10) {
                                Image(systemName: "iphone")
                                    .font(.caption)
                                    .foregroundStyle(.blue)

                                Text(active.name.replacingOccurrences(of: "_", with: " "))
                                    .font(.body)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            let otherStreams = session.availableStreams.filter { name in
                !session.phoneActiveStreams.contains { $0.name == name }
            }
            if !otherStreams.isEmpty {
                Section(session.phoneActiveStreams.isEmpty ? "Cameras" : "All Cameras") {
                    ForEach(otherStreams, id: \.self) { name in
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
                }
            }
        }
        .listStyle(.carousel)
    }

    private var notReachableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)

            Text("Make sure TileCam\nis open on iPhone")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var noStreamsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Add a camera on\niPhone to get started")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
