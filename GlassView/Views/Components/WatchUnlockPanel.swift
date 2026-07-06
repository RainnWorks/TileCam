import SwiftUI

/// Glass paywall panel for the iPhone/iPad. Sells the one-time Apple Watch
/// unlock IAP. The phone/iPad app itself is free — this gates only the Watch.
struct WatchUnlockPanel: View {
    @EnvironmentObject var store: StoreManager
    var onDismiss: () -> Void

    @State private var visible = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Title row
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Watch")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .opacity(visible ? 1 : 0)
                            .offset(y: visible ? 0 : 4)
                            .animation(.smooth(duration: 0.3).delay(visible ? 0 : 0.06), value: visible)

                        Text("One-time unlock")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.35))
                            .opacity(visible ? 1 : 0)
                            .animation(.smooth(duration: 0.3).delay(visible ? 0.06 : 0.03), value: visible)
                    }
                    Spacer()
                    Button {
                        dismiss()
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
                    .animation(.smooth(duration: 0.3).delay(visible ? 0.09 : 0), value: visible)
                    .accessibilityLabel("Close")
                }

                // Hero
                heroSection
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 6)
                    .animation(.smooth(duration: 0.3).delay(visible ? 0.12 : 0), value: visible)

                if store.isWatchUnlocked {
                    unlockedSection
                        .opacity(visible ? 1 : 0)
                        .offset(y: visible ? 0 : 6)
                        .animation(.smooth(duration: 0.3).delay(visible ? 0.18 : 0), value: visible)
                } else {
                    buySection
                        .opacity(visible ? 1 : 0)
                        .offset(y: visible ? 0 : 6)
                        .animation(.smooth(duration: 0.3).delay(visible ? 0.18 : 0), value: visible)
                }

                familySharingNote
                    .opacity(visible ? 1 : 0)
                    .animation(.smooth(duration: 0.3).delay(visible ? 0.24 : 0), value: visible)
            }
            .padding(24)
        }
        .frame(maxWidth: 380, maxHeight: 520)
        .contentShape(Rectangle())
        .glassBackground(cornerRadius: 24)
        .padding(.horizontal, 24)
        .onAppear { visible = true }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "applewatch.side.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.8))

            Text("Stream cameras on your wrist")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            Text("Watch your live feeds on Apple Watch with full pan and zoom. A single purchase unlocks it forever.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Buy

    private var buySection: some View {
        VStack(spacing: 12) {
            Button {
                Task { await store.purchase() }
            } label: {
                HStack(spacing: 8) {
                    if store.isPurchasing {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.7)
                    }
                    Text(buyButtonTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(store.isPurchasing ? 0.08 : 0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.white.opacity(0.2), lineWidth: 0.5)
                        )
                )
                .contentShape(Rectangle())
            }
            .disabled(store.isPurchasing || store.product == nil)
            .accessibilityIdentifier("paywall-unlock-button")
            .accessibilityLabel("Unlock Apple Watch")

            Button {
                Task { await store.restore() }
            } label: {
                Text("Restore Purchases")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(store.isPurchasing)
            .accessibilityLabel("Restore Purchases")
        }
        .animation(.smooth(duration: 0.2), value: store.isPurchasing)
    }

    private var buyButtonTitle: String {
        if store.isPurchasing { return "Unlocking…" }
        if let price = store.product?.displayPrice {
            return "Unlock Apple Watch · \(price)"
        }
        return "Unlock Apple Watch"
    }

    // MARK: - Unlocked

    private var unlockedSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unlocked")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Apple Watch streaming is enabled.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.green.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.green.opacity(0.2), lineWidth: 0.5)
                )
        )
        .accessibilityIdentifier("paywall-unlocked-confirmation")
    }

    // MARK: - Family Sharing

    private var familySharingNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.25))
            Text("Family Sharing supported. One purchase covers your whole family.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.25))
            Spacer()
        }
    }

    private func dismiss() {
        visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDismiss()
        }
    }
}
