import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: StoreManager
    @ObservedObject private var phoneSession = PhoneSessionManager.shared
    @State private var showUI = true
    @State private var showServerInput = false
    @State private var showWatchSettings = false
    @State private var showWatchUnlock = false
    @State private var showSettings = false
    @State private var hideTimer: Task<Void, Never>?
    @State private var animateTokens = false

    private let autoHideDelay: Duration = .seconds(4)
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// Whether to surface the Watch settings entry point. Normally gated on a
    /// reachable paired Watch; under UI test (DEBUG + `-uiTestForceWatchUI`) we
    /// force it on so the paywall/lock-state flow is queryable on a simulator
    /// with no paired Watch. Zero effect in normal use.
    private var watchUIAvailable: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "uiTestForceWatchUI") { return true }
        #endif
        return phoneSession.isWatchReachable
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if appState.serverURL.isEmpty {
                // First-time setup — full screen
                serverInputPanel
            } else {
                // Camera feeds
                TileGridView()
                    .environment(\.showUI, showUI)
                    .environment(\.toggleUI, { [self] in toggleUI() })
                    .ignoresSafeArea()
                    .onTapGesture { toggleUI() }

                // Video dimming overlay — sits above the feeds, below UI chrome.
                // allowsHitTesting(false) so taps fall through to toggleUI.
                if appState.videoDimmingEnabled {
                    Color.black
                        .opacity(appState.videoDimmingAmount)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .animation(.smooth(duration: 0.2), value: appState.videoDimmingAmount)
                        .animation(.smooth(duration: 0.2), value: appState.videoDimmingEnabled)
                }

                // All UI fades in/out together
                if showUI {
                    VStack {
                        // Top bar
                        HStack {
                            Spacer()

                            Button {
                                withAnimation(.smooth(duration: 0.2)) {
                                    appState.isGlobalAudioEnabled.toggle()
                                }
                                haptic.impactOccurred()
                                keepUIVisible()
                            } label: {
                                Image(systemName: appState.isGlobalAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                    .font(.body)
                                    .foregroundStyle(.white)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .liquidGlassCircle()
                            .contentShape(Rectangle())
                            .accessibilityLabel(appState.isGlobalAudioEnabled ? "Audio on" : "Audio muted")
                            .accessibilityHint("Toggle audio")

                            Button {
                                withAnimation(.smooth(duration: 0.25)) {
                                    showSettings.toggle()
                                    showServerInput = false
                                    showWatchSettings = false
                                    showWatchUnlock = false
                                }
                                keepUIVisible()
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.body)
                                    .foregroundStyle(.white)
                            }
                            .liquidGlassCircle()
                            .contentShape(Rectangle())
                            .accessibilityLabel("Settings")

                            if watchUIAvailable {
                                Button {
                                    withAnimation(.smooth(duration: 0.25)) {
                                        showWatchSettings.toggle()
                                        showServerInput = false
                                        showSettings = false
                                        showWatchUnlock = false
                                    }
                                    keepUIVisible()
                                } label: {
                                    ZStack(alignment: .topTrailing) {
                                        Image(systemName: "applewatch")
                                            .font(.body)
                                            .foregroundStyle(.white)
                                        if phoneSession.isWatchStreamDegraded {
                                            Circle()
                                                .fill(.orange)
                                                .frame(width: 8, height: 8)
                                                .offset(x: 2, y: -2)
                                        }
                                    }
                                }
                                .liquidGlassCircle()
                                .contentShape(Rectangle())
                                .accessibilityIdentifier("watch-settings-button")
                                .accessibilityLabel("Watch settings")
                            }

                            Button {
                                withAnimation {
                                    showServerInput.toggle()
                                    showWatchSettings = false
                                    showSettings = false
                                    showWatchUnlock = false
                                }
                                keepUIVisible()
                            } label: {
                                Image(systemName: "server.rack")
                                    .font(.body)
                                    .foregroundStyle(.white)
                            }
                            .liquidGlassCircle()
                            .contentShape(Rectangle())
                            .accessibilityLabel("Server settings")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        Spacer()

                        // Bottom: stream tokens in glass panel
                        if !appState.availableStreams.isEmpty {
                            streamTokenPanel
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .transition(.opacity)

                    // Server input overlay
                    if showServerInput {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation { showServerInput = false }
                            }

                        serverInputPanel
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }

                    // Watch settings overlay
                    if showWatchSettings {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.smooth(duration: 0.25)) { showWatchSettings = false }
                            }

                        watchSettingsPanel
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }

                    // Settings overlay
                    if showSettings {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.smooth(duration: 0.25)) { showSettings = false }
                            }

                        settingsPanel
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }

                    // Watch unlock (paywall) overlay
                    if showWatchUnlock {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.smooth(duration: 0.25)) { showWatchUnlock = false }
                            }

                        watchUnlockPanel
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: showUI)
        .animation(.smooth(duration: 0.25), value: showServerInput)
        .animation(.smooth(duration: 0.25), value: showWatchSettings)
        .animation(.smooth(duration: 0.25), value: showWatchUnlock)
        .animation(.smooth(duration: 0.25), value: showSettings)
        .task {
            await appState.refreshStreams()
            scheduleAutoHide()
            applyIdleTimer()
        }
        .onChange(of: appState.selectedStreams) { _, _ in applyIdleTimer() }
        .onChange(of: appState.serverURL) { _, _ in applyIdleTimer() }
        .onChange(of: appState.keepScreenAwake) { _, _ in applyIdleTimer() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #if targetEnvironment(macCatalyst)
        .onKeyPress(.space) {
            toggleUI()
            return .handled
        }
        .onKeyPress(.escape) {
            if showSettings {
                withAnimation(.smooth(duration: 0.25)) { showSettings = false }
            } else if showWatchSettings {
                withAnimation(.smooth(duration: 0.25)) { showWatchSettings = false }
            } else if showServerInput {
                withAnimation { showServerInput = false }
            } else if showUI {
                withAnimation { showUI = false }
            }
            return .handled
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard showUI, let digit = Int(press.characters), digit >= 1,
                  digit <= appState.availableStreams.count else {
                return .ignored
            }
            let stream = appState.availableStreams[digit - 1]
            withAnimation(.smooth(duration: 0.2)) {
                if appState.selectedStreams.contains(stream) {
                    appState.selectedStreams.removeAll { $0 == stream }
                } else {
                    appState.selectedStreams.append(stream)
                }
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "m")) { _ in
            withAnimation(.smooth(duration: 0.2)) {
                appState.isGlobalAudioEnabled.toggle()
            }
            return .handled
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard press.modifiers.contains(.option),
                  let digit = Int(press.characters), digit >= 1,
                  digit <= appState.availableStreams.count else {
                return .ignored
            }
            let stream = appState.availableStreams[digit - 1]
            withAnimation(.smooth(duration: 0.2)) {
                appState.toggleStreamMute(stream.name)
            }
            return .handled
        }
        #endif
    }

    // MARK: - Auto-hide

    private func toggleUI() {
        withAnimation(.smooth(duration: 0.25)) {
            showUI.toggle()
            if !showUI {
                showServerInput = false
                showWatchSettings = false
            }
        }
        if showUI {
            scheduleAutoHide()
        }
    }

    private func keepUIVisible() {
        scheduleAutoHide()
    }

    private func applyIdleTimer() {
        let streaming = !appState.serverURL.isEmpty && !appState.selectedStreams.isEmpty
        UIApplication.shared.isIdleTimerDisabled = streaming && appState.keepScreenAwake
    }

    private func scheduleAutoHide() {
        hideTimer?.cancel()
        // Don't auto-hide if no streams selected — user needs to see the UI
        guard !appState.selectedStreams.isEmpty else { return }
        hideTimer = Task {
            try? await Task.sleep(for: autoHideDelay)
            guard !Task.isCancelled else { return }
            if !showServerInput && !showWatchSettings && !showSettings && !showWatchUnlock {
                withAnimation(.smooth(duration: 0.4)) {
                    showUI = false
                }
            }
        }
    }

    // MARK: - Server Input

    private var serverInputPanel: some View {
        ServerInputPanel(
            serverURL: appState.serverURL,
            onConnect: { url in
                let serverChanged = url != appState.serverURL
                appState.serverURL = url
                if serverChanged {
                    appState.selectedStreams = []
                    appState.availableStreams = []
                }
                withAnimation { showServerInput = false }
                Task { await appState.refreshStreams() }
            }
        )
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        SettingsPanel(onDismiss: {
            withAnimation(.smooth(duration: 0.25)) { showSettings = false }
        })
        .environmentObject(appState)
    }

    // MARK: - Watch Settings Panel

    private var watchSettingsPanel: some View {
        WatchSettingsPanel(
            wristBehavior: Binding(
                get: { WristBehavior(rawValue: appState.wristBehavior) ?? .eco },
                set: { appState.wristBehavior = $0.rawValue }
            ),
            onDismiss: {
                withAnimation(.smooth(duration: 0.25)) { showWatchSettings = false }
            },
            onUnlockTapped: {
                withAnimation(.smooth(duration: 0.25)) {
                    showWatchSettings = false
                    showWatchUnlock = true
                }
            }
        )
        .environmentObject(appState)
        .environmentObject(store)
    }

    // MARK: - Watch Unlock Panel

    private var watchUnlockPanel: some View {
        WatchUnlockPanel(onDismiss: {
            withAnimation(.smooth(duration: 0.25)) { showWatchUnlock = false }
        })
        .environmentObject(store)
    }

    // MARK: - Stream Token Panel

    private var streamTokenPanel: some View {
        VStack(spacing: 0) {
            FlowLayout(spacing: 8) {
                ForEach(Array(appState.availableStreams.enumerated()), id: \.element.id) { index, stream in
                    let isSelected = appState.selectedStreams.contains(stream)
                    let displayName = stream.name.replacingOccurrences(of: "_", with: " ")
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            if isSelected {
                                appState.selectedStreams.removeAll { $0 == stream }
                            } else {
                                appState.selectedStreams.append(stream)
                            }
                        }
                        haptic.impactOccurred()
                        keepUIVisible()
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isSelected ? .green : .white.opacity(0.35))
                                .frame(width: 6, height: 6)
                                .shadow(color: isSelected ? .green.opacity(0.4) : .clear, radius: isSelected ? 3 : 0)

                            Text(displayName)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isSelected ? .white.opacity(0.15) : .white.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(displayName)
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.7), value: isSelected)
                    .opacity(animateTokens ? 1 : 0)
                    .offset(y: animateTokens ? 0 : 4)
                    .animation(.smooth(duration: 0.25).delay(Double(index) * 0.04), value: animateTokens)
                }
            }
            .padding(12)
        }
        .contentShape(Rectangle())
        .liquidGlass(in: .rect(cornerRadius: 20))
        .frame(maxWidth: 500)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onChange(of: appState.availableStreams) { old, new in
            if old.isEmpty && !new.isEmpty {
                animateTokens = false
                withAnimation { animateTokens = true }
            }
        }
        .onAppear {
            if !appState.availableStreams.isEmpty {
                animateTokens = true
            }
        }
    }
}

// MARK: - Server Input Panel (staggered entrance)

private struct ServerInputPanel: View {
    let serverURL: String
    let onConnect: (String) -> Void
    @State private var visible = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image("TileCamLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.white.opacity(0.8))
                    .opacity(visible ? 1 : 0)
                    .scaleEffect(visible ? 1 : 0.9)
                    .animation(.smooth(duration: 0.35), value: visible)

                Text("TileCam")
                    .font(.title.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 4)
                    .animation(.smooth(duration: 0.3).delay(0.06), value: visible)

                Text("Multi-camera streaming")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
                    .opacity(visible ? 1 : 0)
                    .animation(.smooth(duration: 0.3).delay(0.12), value: visible)
            }

            ServerInputField(
                initialURL: serverURL,
                onConnect: onConnect
            )
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 6)
            .animation(.smooth(duration: 0.3).delay(0.15), value: visible)
        }
        .padding(32)
        .frame(maxWidth: 400)
        .contentShape(Rectangle())
        .glassBackground(cornerRadius: 24)
        .padding(.horizontal, 32)
        .onAppear { visible = true }
    }
}

// MARK: - Server Input Field

private struct ServerInputField: View {
    let initialURL: String
    let onConnect: (String) -> Void
    @State private var urlInput = ""
    @State private var testing = false
    @State private var status: Status?

    enum Status {
        case success(Int)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "link")
                    .foregroundStyle(.white.opacity(0.4))
                    .font(.caption)

                TextField("", text: $urlInput, prompt:
                    Text("http://192.168.1.100:1984")
                        .foregroundStyle(.white.opacity(0.3))
                )
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .submitLabel(.go)
                    .onSubmit { connect() }
                    .accessibilityLabel("Server URL")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassBackground(cornerRadius: 12)

            if let status {
                HStack(spacing: 4) {
                    switch status {
                    case .success(let n):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(n) streams found").foregroundStyle(.green)
                    case .failure(let msg):
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(msg).foregroundStyle(.red).lineLimit(2)
                    }
                }
                .font(.caption2)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 8) {
                Button {
                    guard !testing else { return }
                    Task { await test() }
                } label: {
                    HStack(spacing: 4) {
                        if testing { ProgressView().tint(.white).scaleEffect(0.6) }
                        Text("Test")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
                .liquidGlassToken()
                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                .accessibilityLabel(testing ? "Testing connection" : "Test connection")

                Button {
                    connect()
                } label: {
                    Text("Connect")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .liquidGlassToken()
                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Connect to server")
            }
        }
        .onAppear {
            urlInput = initialURL
        }
    }

    private var normalizedURL: String {
        var url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return "" }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://" + url
        }
        if url.hasSuffix("/") { url.removeLast() }
        return url
    }

    private func connect() {
        let url = normalizedURL
        guard !url.isEmpty, URL(string: url) != nil else {
            withAnimation { status = .failure("Invalid URL") }
            return
        }
        onConnect(url)
    }

    private func test() async {
        testing = true
        status = nil
        let url = normalizedURL
        guard !url.isEmpty, let parsedURL = URL(string: url) else {
            withAnimation { status = .failure("Invalid URL") }
            testing = false
            return
        }
        let service = Go2RTCService(baseURL: parsedURL)
        do {
            let streams = try await service.fetchStreams()
            withAnimation { status = .success(streams.count) }
        } catch {
            withAnimation { status = .failure(error.localizedDescription) }
        }
        testing = false
    }
}

// MARK: - Flow Layout (for stream tokens)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        let contentWidth = result.size.width
        for (index, position) in result.positions.enumerated() {
            let row = result.rowIndices[index]
            let rowWidth = result.rowWidths[row]
            let centeredX = bounds.minX + position.x + (contentWidth - rowWidth) / 2
            subviews[index].place(at: CGPoint(x: centeredX, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
        var rowIndices: [Int]
        var rowWidths: [CGFloat]
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var rowIndices: [Int] = []
        var rowWidths: [CGFloat] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var currentRow = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                rowWidths.append(x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
                currentRow += 1
            }
            positions.append(CGPoint(x: x, y: y))
            rowIndices.append(currentRow)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        rowWidths.append(x - spacing)

        let contentWidth = rowWidths.max() ?? 0
        return LayoutResult(
            size: CGSize(width: contentWidth, height: y + rowHeight),
            positions: positions,
            rowIndices: rowIndices,
            rowWidths: rowWidths
        )
    }
}
