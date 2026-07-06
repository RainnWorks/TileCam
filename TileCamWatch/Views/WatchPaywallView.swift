import SwiftUI

/// Shown on the Watch when the unlock IAP has not been purchased. There is NO
/// purchase UI here — the unlock is sold only from iPhone/iPad. This is a
/// hard lock: nothing streams until the entitlement arrives from the phone.
struct WatchPaywallView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "lock.applewatch")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))

                Text("Locked")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("Unlock TileCam on your iPhone to stream cameras here.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                    Text("TileCam › Apple Watch")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.white.opacity(0.15), lineWidth: 0.5)
                        )
                )
                .padding(.top, 4)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
    }
}
