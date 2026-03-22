import SwiftUI

/// Glass panel containing Watch-related settings for the iPhone app.
struct WatchSettingsPanel: View {
    @Binding var wristBehavior: WristBehavior
    var onDismiss: () -> Void

    @State private var visible = false

    var body: some View {
        VStack(spacing: 24) {
            // Title row
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Watch")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .opacity(visible ? 1 : 0)
                        .offset(y: visible ? 0 : 4)
                        .animation(.smooth(duration: 0.3), value: visible)

                    Text("Streaming preferences")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .opacity(visible ? 1 : 0)
                        .animation(.smooth(duration: 0.3).delay(0.06), value: visible)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .opacity(visible ? 1 : 0)
                .animation(.smooth(duration: 0.3).delay(0.09), value: visible)
                .accessibilityLabel("Close")
            }

            // Wrist behavior picker
            WristBehaviorPicker(selection: $wristBehavior)
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 6)
                .animation(.smooth(duration: 0.3).delay(0.12), value: visible)
        }
        .padding(24)
        .frame(maxWidth: 380)
        .contentShape(Rectangle())
        .glassBackground(cornerRadius: 24)
        .padding(.horizontal, 24)
        .onAppear { visible = true }
    }
}
