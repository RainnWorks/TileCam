import SwiftUI

struct AudioWaveformIndicator: View {
    let level: Float
    let isMuted: Bool

    private static let barCount = 3
    private let barWidths: [CGFloat] = [2.5, 2.5, 2.5]

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(barColor)
                    .frame(width: barWidths[index])
                    .scaleEffect(y: barHeight(for: index), anchor: .bottom)
            }
        }
        .frame(width: 12, height: 10)
        .animation(.smooth(duration: 0.15), value: level)
    }

    private var barColor: Color {
        if isMuted {
            return .white.opacity(0.2)
        }
        if level > 0.5 {
            return .orange.opacity(0.6)
        }
        return .white.opacity(0.4)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let clampedLevel = CGFloat(min(max(level, 0), 1))
        let minHeight: CGFloat = 0.15

        // Each bar gets a slightly different proportion of the level
        let multiplier: CGFloat = switch index {
        case 0: 0.7
        case 1: 1.0
        case 2: 0.5
        default: 0.6
        }

        return max(minHeight, clampedLevel * multiplier)
    }
}
