import SwiftUI

struct TileGridView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geo in
            let streams = appState.selectedStreams.uniqued()

            if streams.isEmpty {
                // Empty state — nudge user to select streams
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.2))
                    Text("Tap a stream below to start")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let service = appState.go2rtcService {
                let layout = tileLayout(count: streams.count, size: geo.size)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: layout.columns),
                    spacing: 2
                ) {
                    ForEach(streams) { stream in
                        StreamTileView(
                            stream: stream,
                            service: service
                        )
                        .id(stream.id)
                        .frame(height: layout.tileHeight)
                        .contentShape(Rectangle())
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .transition(.opacity.animation(.easeIn(duration: 0.2)))
                    }
                }
                .animation(.smooth(duration: 0.3), value: streams.map(\.id))
                .padding(2)
            }
        }
    }

    struct TileLayout {
        let columns: Int
        let tileHeight: CGFloat
    }

    func tileLayout(count: Int, size: CGSize) -> TileLayout {
        let isLandscape = size.width > size.height

        let columns: Int
        switch count {
        case 0:
            columns = 1
        case 1:
            columns = 1
        case 2:
            columns = isLandscape ? 2 : 1
        case 3, 4:
            columns = 2
        case 5, 6:
            columns = isLandscape ? 3 : 2
        case 7...9:
            columns = 3
        default:
            columns = isLandscape ? 4 : 3
        }

        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let totalSpacing = CGFloat(rows - 1) * 4 + 8
        let tileHeight = max(100, (size.height - totalSpacing) / CGFloat(rows))

        return TileLayout(columns: columns, tileHeight: tileHeight)
    }
}
