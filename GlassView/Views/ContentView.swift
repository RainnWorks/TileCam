import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showUI = true
    @State private var showServerInput = false
    @State private var hideTimer: Task<Void, Never>?

    private let autoHideDelay: Duration = .seconds(4)

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
                        // Top: settings button
                        HStack {
                            Spacer()
                            Button {
                                withAnimation { showServerInput.toggle() }
                                keepUIVisible()
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.body)
                                    .foregroundStyle(.white)
                            }
                            .liquidGlassCircle()
                            .contentShape(Rectangle())
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
        VStack(spacing: 20) {
            Image(systemName: "video.doorbell.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.7))

            Text("GlassView")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)

            ServerInputField(
                initialURL: appState.serverURL,
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
        .padding(28)
        .contentShape(Rectangle())
        .glassBackground(cornerRadius: 24)
        .padding(.horizontal, 32)
    }

    // MARK: - Stream Token Panel

    private var streamTokenPanel: some View {
        VStack(spacing: 0) {
            FlowLayout(spacing: 8) {
                ForEach(appState.availableStreams) { stream in
                    let isSelected = appState.selectedStreams.contains(stream)
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            if isSelected {
                                appState.selectedStreams.removeAll { $0 == stream }
                            } else {
                                appState.selectedStreams.append(stream)
                            }
                        }
                        keepUIVisible()
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(isSelected ? .green : .white.opacity(0.3))
                                .frame(width: 6, height: 6)

                            Text(stream.name.replacingOccurrences(of: "_", with: " "))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isSelected ? .white.opacity(0.1) : .clear)
                        )
                    }
                    .opacity(isSelected ? 1 : 0.7)
                }
            }
            .padding(12)
        }
        .contentShape(Rectangle())
        .glassBackground(cornerRadius: 20)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
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

                Button {
                    connect()
                } label: {
                    Text("Connect")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .liquidGlassToken()
                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty)
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
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
