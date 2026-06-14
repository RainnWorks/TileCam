import Foundation

struct Stream: Identifiable, Hashable, Codable {
    let name: String
    var id: String { name }
}

// MARK: - Per-stream view state (zoom, pan)

struct StreamViewState: Codable, Equatable {
    /// Hard ceiling on persisted zoom. Mirrors `StreamTileView.limitTransform`'s cap so a
    /// corrupt blob can never apply an insane zoom even before content size is known.
    static let maxZoom: Double = 20.0

    var zoom: Double = 1.0
    var panX: Double = 0.0
    var panY: Double = 0.0

    /// Returns a copy with non-finite values rejected (treated as identity) and zoom
    /// clamped into `[1, maxZoom]`. Pan is bounded later by `limitTransform` once the
    /// content size is known.
    func sanitized() -> StreamViewState {
        guard zoom.isFinite, panX.isFinite, panY.isFinite else {
            return StreamViewState()
        }
        var s = self
        s.zoom = min(max(zoom, 1.0), Self.maxZoom)
        return s
    }
}

// MARK: - Persisted layout store

@MainActor
final class LayoutStore {
    private static let selectedKey = "selectedStreamNames"
    private static let viewStatesKey = "streamViewStates"

    static func saveSelectedStreams(_ streams: [Stream]) {
        let names = streams.map(\.name)
        UserDefaults.standard.set(names, forKey: selectedKey)
    }

    static func loadSelectedStreams() -> [Stream] {
        let names = UserDefaults.standard.stringArray(forKey: selectedKey) ?? []
        return names.map { Stream(name: $0) }
    }

    static func saveViewState(_ state: StreamViewState, for streamName: String) {
        var all = loadAllViewStates()
        all[streamName] = state
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: viewStatesKey)
        }
    }

    static func loadViewState(for streamName: String) -> StreamViewState {
        (loadAllViewStates()[streamName] ?? StreamViewState()).sanitized()
    }

    private static func loadAllViewStates() -> [String: StreamViewState] {
        guard let data = UserDefaults.standard.data(forKey: viewStatesKey),
              let decoded = try? JSONDecoder().decode([String: StreamViewState].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

extension Array where Element: Identifiable {
    func uniqued() -> [Element] {
        var seen = Set<String>()
        return filter { element in
            let id = "\(element.id)"
            return seen.insert(id).inserted
        }
    }
}
