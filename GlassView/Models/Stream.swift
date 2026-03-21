import Foundation

struct Stream: Identifiable, Hashable, Codable {
    let name: String
    var id: String { name }
}

/// Response from go2rtc /api/streams
struct StreamsResponse: Codable {
    /// Keys are stream names, values are stream source arrays
    let streams: [String: [StreamSource]]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: [StreamSource]].self)
        streams = raw
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(streams)
    }
}

struct StreamSource: Codable, Hashable {
    let url: String?
}

// MARK: - Video content mode (like CSS object-fit)

enum VideoContentMode: String, Codable, CaseIterable, Identifiable {
    case cover   // scaleAspectFill — fills the tile, may crop
    case contain // scaleAspectFit — fits fully, may letterbox
    case fill    // scaleToFill — stretches to fill exactly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cover: return "Cover"
        case .contain: return "Contain"
        case .fill: return "Fill"
        }
    }

    var icon: String {
        switch self {
        case .cover: return "rectangle.arrowtriangle.2.outward"
        case .contain: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.dashed"
        }
    }
}

// MARK: - Per-stream view state (zoom, pan, content mode)

struct StreamViewState: Codable, Equatable {
    var zoom: Double = 1.0
    var panX: Double = 0.0
    var panY: Double = 0.0
    var contentMode: VideoContentMode = .cover
}

// MARK: - Persisted layout store

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
        loadAllViewStates()[streamName] ?? StreamViewState()
    }

    static func loadAllViewStates() -> [String: StreamViewState] {
        guard let data = UserDefaults.standard.data(forKey: viewStatesKey),
              let decoded = try? JSONDecoder().decode([String: StreamViewState].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func saveGlobalContentMode(_ mode: VideoContentMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "globalContentMode")
    }

    static func loadGlobalContentMode() -> VideoContentMode {
        guard let raw = UserDefaults.standard.string(forKey: "globalContentMode"),
              let mode = VideoContentMode(rawValue: raw) else {
            return .cover
        }
        return mode
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
