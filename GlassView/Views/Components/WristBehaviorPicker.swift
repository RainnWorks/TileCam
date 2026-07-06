import SwiftUI

/// The three wrist-down behavior options, presented without jargon.
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
        case .eco: return "Saves battery. Stops when you lower your wrist."
        case .audioOnly: return "Keep listening even when you're not looking."
        case .alwaysOn: return "Instant view when you raise your wrist. Uses more battery."
        }
    }
}

/// Glass segmented picker for wrist-down behavior.
/// Designed to be placed in the iPhone settings panel.
struct WristBehaviorPicker: View {
    @Binding var selection: WristBehavior

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let segmentHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "applewatch")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.35))
                Text("When you lower your wrist")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }

            // Glass segmented control
            GeometryReader { geo in
                let segmentWidth = max(geo.size.width, 1) / CGFloat(WristBehavior.allCases.count)
                let selectedIndex = CGFloat(WristBehavior.allCases.firstIndex(of: selection) ?? 0)

                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.white.opacity(0.08), lineWidth: 0.5)
                        )

                    // Sliding selection indicator
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.white.opacity(0.2), lineWidth: 0.5)
                        )
                        .frame(width: segmentWidth - 6)
                        .padding(3)
                        .offset(x: selectedIndex * segmentWidth)
                        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.75), value: selection)

                    // Segments
                    HStack(spacing: 0) {
                        ForEach(WristBehavior.allCases) { behavior in
                            let isSelected = selection == behavior
                            Button {
                                haptic.prepare()
                                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.75)) {
                                    selection = behavior
                                }
                                haptic.impactOccurred()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: behavior.icon)
                                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                        .symbolRenderingMode(.hierarchical)
                                    Text(behavior.title)
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                }
                                .foregroundStyle(isSelected ? .white : .white.opacity(0.35))
                                .animation(.smooth(duration: 0.2), value: selection)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
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

            // Description text — cross-fade between values
            Text(selection.subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 36, alignment: .top)
                .id(selection)
                .transition(.opacity)
                .animation(.smooth(duration: 0.2), value: selection)

            // Battery indicator
            batteryHint
        }
    }

    private var batteryHint: some View {
        HStack(spacing: 4) {
            let level: Int = {
                switch selection {
                case .eco: return 1
                case .audioOnly: return 2
                case .alwaysOn: return 3
                }
            }()

            Image(systemName: batteryIcon)
                .font(.system(size: 10))
                .foregroundStyle(batteryColor)

            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < level ? batteryColor : .white.opacity(0.08))
                        .frame(width: 12, height: 4)
                }
            }

            Text(batteryLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(batteryColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(batteryLabel)
        .animation(.smooth(duration: 0.2), value: selection)
    }

    private var batteryIcon: String {
        switch selection {
        case .eco: return "battery.25percent"
        case .audioOnly: return "battery.50percent"
        case .alwaysOn: return "battery.75percent"
        }
    }

    private var batteryColor: Color {
        switch selection {
        case .eco: return .green.opacity(0.6)
        case .audioOnly: return .yellow.opacity(0.6)
        case .alwaysOn: return .orange.opacity(0.6)
        }
    }

    private var batteryLabel: String {
        switch selection {
        case .eco: return "Low battery use"
        case .audioOnly: return "Medium battery use"
        case .alwaysOn: return "Higher battery use"
        }
    }
}
