import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showUI = true
    @State private var showServerInput = false
    @State private var hideTimer: Task<Void, Never>?
    @State private var animateTokens = false

    private let autoHideDelay: Duration = .seconds(4)
    private let haptic = UIImpactFeedbackGenerator(style: .light)

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

                // All UI fades in/out together
                if showUI {
                    VStack {
                        // Top: server button
                        HStack {
                            Spacer()

                            Button {
                                withAnimation { showServerInput.toggle() }
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
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: showUI)
        .animation(.smooth(duration: 0.25), value: showServerInput)
        .task {
            await appState.refreshStreams()
            scheduleAutoHide()
        }
        #if targetEnvironment(macCatalyst)
        .onKeyPress(.space) {
            toggleUI()
            return .handled
        }
        .onKeyPress(.escape) {
            if showServerInput {
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
        #endif
    }

    // MARK: - Auto-hide

    private func toggleUI() {
        withAnimation(.smooth(duration: 0.25)) {
            showUI.toggle()
            if !showUI {
                showServerInput = false
            }
        }
        if showUI {
            scheduleAutoHide()
        }
    }

    private func keepUIVisible() {
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideTimer?.cancel()
        // Don't auto-hide if no streams selected — user needs to see the UI
        guard !appState.selectedStreams.isEmpty else { return }
        hideTimer = Task {
            try? await Task.sleep(for: autoHideDelay)
            guard !Task.isCancelled else { return }
            if !showServerInput {
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
                                .fill(isSelected ? .green : .white.opacity(0.2))
                                .frame(width: isSelected ? 8 : 6, height: isSelected ? 8 : 6)
                                .shadow(color: isSelected ? .green.opacity(0.4) : .clear, radius: isSelected ? 3 : 0)
                                .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.6), value: isSelected)

                            Text(displayName)
                                .font(.caption.weight(isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? .white : .white.opacity(0.4))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isSelected ? .white.opacity(0.2) : .clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(isSelected ? .clear : .white.opacity(0.1), lineWidth: 0.5)
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(displayName)
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .scaleEffect(isSelected ? 1.0 : 0.97)
                    .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.7), value: isSelected)
                    .opacity(isSelected ? 1 : 0.5)
                    .opacity(animateTokens ? 1 : 0)
                    .offset(y: animateTokens ? 0 : 4)
                    .animation(.smooth(duration: 0.25).delay(Double(index) * 0.04), value: animateTokens)
                }
            }
            .padding(12)
        }
        .contentShape(Rectangle())
        .glassBackground(cornerRadius: 20)
        .padding(.horizontal, 8)
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
        let maxWidth = proposal.width ?? bounds.width
        for (index, position) in result.positions.enumerated() {
            let row = result.rowIndices[index]
            let rowWidth = result.rowWidths[row]
            let centeredX = bounds.minX + position.x + (maxWidth - rowWidth) / 2
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

        return LayoutResult(
            size: CGSize(width: maxWidth, height: y + rowHeight),
            positions: positions,
            rowIndices: rowIndices,
            rowWidths: rowWidths
        )
    }
}
