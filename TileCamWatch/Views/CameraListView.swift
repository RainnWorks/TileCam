import SwiftUI

struct CameraListView: View {
    @EnvironmentObject var session: WatchSessionManager
    @State private var navigateToStream: String?

    var body: some View {
        NavigationStack {
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
            .navigationDestination(for: String.self) { streamName in
                CameraSnapshotView(streamName: streamName)
                    .environmentObject(session)
            }
            .onChange(of: session.pushedStreamName) { _, pushed in
                if let pushed {
                    navigateToStream = pushed
                    session.pushedStreamName = nil
                }
            }
        }
    }

    private var streamList: some View {
        List(session.availableStreams, id: \.self) { name in
            NavigationLink(value: name) {
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

            Text("Open TileCam\non iPhone")
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
