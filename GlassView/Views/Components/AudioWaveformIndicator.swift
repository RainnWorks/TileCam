import SwiftUI

struct AudioWaveformIndicator: View {
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3) { index in
                WaveformBar(index: index)
            }
        }
        .frame(width: 12, height: 8)
    }
}

private struct WaveformBar: View {
    let index: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(.white.opacity(0.4))
            .phaseAnimator([false, true]) { content, phase in
                content.scaleEffect(
                    y: phase ? barScale(for: index) : 0.4,
                    anchor: .bottom
                )
            } animation: { _ in
                .easeInOut(duration: duration(for: index))
            }
    }

    private func barScale(for index: Int) -> CGFloat {
        switch index {
        case 0: 0.7
        case 1: 1.0
        case 2: 0.5
        default: 0.6
        }
    }

    private func duration(for index: Int) -> Double {
        switch index {
        case 0: 0.6
        case 1: 0.8
        case 2: 0.5
        default: 0.7
        }
    }
}
