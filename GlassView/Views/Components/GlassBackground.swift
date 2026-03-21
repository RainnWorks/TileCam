import SwiftUI

// MARK: - Fallback glass for < iOS 26

struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(.white.opacity(0.15), lineWidth: 0.5)
                    )
            )
    }
}

extension View {
    func glassBackground(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func liquidGlass(in shape: some InsettableShape = .capsule) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.glassBackground(cornerRadius: 20)
        }
    }

    @ViewBuilder
    func liquidGlassToken() -> some View {
        if #available(iOS 26, *) {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    func liquidGlassCircle() -> some View {
        if #available(iOS 26, *) {
            self
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            self
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}
