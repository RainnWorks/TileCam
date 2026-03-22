import WatchKit
import os

private let log = Logger(subsystem: "works.rainn.tilecam.watch", category: "ExtendedRuntime")

/// Manages a WKExtendedRuntimeSession to keep the Watch app alive
/// during wrist-down when the user has selected Listen or Stay On mode.
///
/// Without an active extended runtime session, watchOS suspends the app
/// within seconds of wrist-down, making background audio impossible.
@MainActor
final class ExtendedRuntimeManager: NSObject, ObservableObject {
    static let shared = ExtendedRuntimeManager()

    @Published var isSessionActive = false

    private var runtimeSession: WKExtendedRuntimeSession?

    /// Starts an extended runtime session if one isn't already active.
    /// Call this when the wrist goes down and the user wants Listen or Stay On.
    func startIfNeeded() {
        guard runtimeSession == nil || runtimeSession?.state == .invalid else {
            log.info("Extended runtime session already active, skipping")
            return
        }

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtimeSession = session
        isSessionActive = true
        log.info("Extended runtime session started")
    }

    /// Invalidates the current extended runtime session.
    /// Call this when returning to eco mode or when the stream ends.
    func stop() {
        guard let session = runtimeSession, session.state == .running || session.state == .scheduled else {
            runtimeSession = nil
            isSessionActive = false
            return
        }
        session.invalidate()
        runtimeSession = nil
        isSessionActive = false
        log.info("Extended runtime session stopped")
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension ExtendedRuntimeManager: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        log.info("Extended runtime session did start")
        Task { @MainActor in
            self.isSessionActive = true
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        log.warning("Extended runtime session will expire soon")
        // The session is about to end. watchOS gives ~30 minutes for smart alarm sessions.
        // We log but don't force-stop — the system will invalidate it.
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        let reasonStr: String
        switch reason {
        case .none: reasonStr = "none"
        case .sessionInProgress: reasonStr = "sessionInProgress"
        case .expired: reasonStr = "expired"
        case .resignedFrontmost: reasonStr = "resignedFrontmost"
        case .error: reasonStr = "error"
        case .suppressedBySystem: reasonStr = "suppressedBySystem"
        @unknown default: reasonStr = "unknown(\(reason.rawValue))"
        }
        log.info("Extended runtime session invalidated: \(reasonStr), error: \(String(describing: error))")
        Task { @MainActor in
            self.runtimeSession = nil
            self.isSessionActive = false
        }
    }
}
