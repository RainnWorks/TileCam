import SwiftUI
import WatchKit

/// The three wrist-down behavior options — matches iPhone enum.
enum WristBehavior: String, CaseIterable, Identifiable {
    case eco = "eco"
    case audioOnly = "audioOnly"
    case alwaysOn = "alwaysOn"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eco: return "Pause"
        case .audioOnly: return "Listen"
        case .alwaysOn: return "Stay On"
        }
    }

    var icon: String {
        switch self {
        case .eco: return "moon.zzz.fill"
        case .audioOnly: return "headphones"
        case .alwaysOn: return "eye.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .eco: return "Stops when you lower your wrist."
        case .audioOnly: return "Keep listening when not looking."
        case .alwaysOn: return "Stays on. Uses more battery."
        }
    }
}

/// Glass segmented picker for wrist-down behavior, adapted for watchOS.
struct WristBehaviorPickerWatch: View {
    @Binding var selection: WristBehavior

    private let segmentHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 10) {
            // Glass segmented control
            GeometryReader { geo in
                let segmentWidth = max(geo.size.width, 1) / CGFloat(WristBehavior.allCases.count)
                let selectedIndex = CGFloat(WristBehavior.allCases.firstIndex(of: selection) ?? 0)

                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.08))

                    // Sliding selection indicator
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.2))
                        .frame(width: segmentWidth - 4)
                        .padding(2)
                        .offset(x: selectedIndex * segmentWidth)
                        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.75), value: selection)

                    // Segments
                    HStack(spacing: 0) {
                        ForEach(WristBehavior.allCases) { behavior in
                            let isSelected = selection == behavior
                            Button {
                                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.75)) {
                                    selection = behavior
                                }
                                WKInterfaceDevice.current().play(.click)
                            } label: {
                                VStack(spacing: 2) {
                                    Image(systemName: behavior.icon)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                        .symbolRenderingMode(.hierarchical)
                                    Text(behavior.title)
                                        .font(.system(size: 9, weight: isSelected ? .bold : .medium))
                                }
                                .foregroundStyle(isSelected ? .white : .white.opacity(0.4))
                                .animation(.smooth(duration: 0.2), value: selection)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 40)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(behavior.title)
                            .accessibilityValue(isSelected ? "Selected" : "Not selected")
                            .accessibilityHint(behavior.subtitle)
                        }
                    }
                }
                .frame(height: segmentHeight)
            }
            .frame(height: segmentHeight)

            // Description
            Text(selection.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 28, alignment: .top)
                .id(selection)
                .transition(.opacity)
                .animation(.smooth(duration: 0.2), value: selection)

            // Battery indicator
            batteryHint
        }
    }

    private var batteryHint: some View {
        HStack(spacing: 3) {
            let level: Int = {
                switch selection {
                case .eco: return 1
                case .audioOnly: return 2
                case .alwaysOn: return 3
                }
            }()

            HStack(spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < level ? batteryColor : .white.opacity(0.1))
                        .frame(width: 10, height: 3)
                }
            }

            Text(batteryLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(batteryColor)
        }
        .animation(.smooth(duration: 0.2), value: selection)
    }

    private var batteryColor: Color {
        switch selection {
        case .eco: return .green.opacity(0.7)
        case .audioOnly: return .yellow.opacity(0.7)
        case .alwaysOn: return .orange.opacity(0.7)
        }
    }

    private var batteryLabel: String {
        switch selection {
        case .eco: return "Low battery"
        case .audioOnly: return "Medium"
        case .alwaysOn: return "Higher use"
        }
    }
}
