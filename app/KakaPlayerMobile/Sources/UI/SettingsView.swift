import SwiftUI

/// Engine address entry: the engines found on this network over Bonjour, and — for
/// anything discovery cannot see — a deliberately small manual form under them.
struct SettingsView: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var discovery = EngineDiscovery()

    @State private var host: String = ""
    @State private var port: String = ""
    @State private var testResult: TestResult = .none
    @State private var testing = false
    /// Set once, when a lone engine was picked without the user asking.
    @State private var autoSelected: String?
    @State private var didAutoSelect = false
    /// The pending "the list has settled, is there exactly one?" check.
    @State private var autoSelectTask: Task<Void, Never>?

    private enum TestResult: Equatable {
        case none
        case ok(String)
        case failed(String)
    }

    private var typedPort: Int { Int(port.trimmingCharacters(in: .whitespaces)) ?? MobileModel.defaultPort }
    /// The address the fields actually mean, with a pasted scheme, path or `:port` folded in.
    private var address: (host: String, port: Int) {
        let parsed = Self.normalize(host)
        return (parsed.host, parsed.port ?? typedPort)
    }
    private var canSave: Bool { !address.host.isEmpty }

    /// Takes what people really paste — `192.168.1.10`, `http://192.168.1.10:6878/`,
    /// `[fe80::1]:6878` — and splits it into a bare host plus a port when one is spelled out,
    /// so the engine URL is not built from something `URL` would reject.
    static func normalize(_ raw: String) -> (host: String, port: Int?) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        for scheme in ["http://", "https://"] {
            if let r = s.range(of: scheme, options: [.caseInsensitive, .anchored]) {
                s = String(s[r.upperBound...])
            }
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {           // [IPv6] or [IPv6]:port
            let literal = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            return (literal, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        return (s, nil)                                                    // host, or a bare IPv6 literal
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("The engine runs on your Mac (KakaPlayer) or another device on this network. In the iOS Simulator the Mac's own engine is reachable at 127.0.0.1.")
                        .font(MobileTheme.rounded(12))
                        .foregroundStyle(MobileTheme.textSecondary)

                    nearbySection

                    sectionTitle("Or type the address")
                    field(title: "Host", text: $host, placeholder: "192.168.1.10", keyboard: .URL)
                    field(title: "Port", text: $port, placeholder: "\(MobileModel.defaultPort)", keyboard: .numberPad)

                    Button { test() } label: {
                        HStack(spacing: 8) {
                            if testing {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text("Test connection").font(MobileTheme.rounded(14, .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .disabled(!canSave || testing)
                    .opacity(!canSave || testing ? 0.5 : 1)

                    switch testResult {
                    case .none:
                        EmptyView()
                    case .ok(let version):
                        resultLine("checkmark.circle.fill", "Engine answered · version \(version)", MobileTheme.ok)
                    case .failed(let message):
                        resultLine("exclamationmark.triangle.fill", message, MobileTheme.warn)
                    }
                }
                .padding(18)
            }
            .background(MobileTheme.bg.ignoresSafeArea())
            .navigationTitle("Engine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(MobileTheme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.setEngine(host: address.host, port: address.port)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? MobileTheme.accent : MobileTheme.textTertiary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            host = model.engineHost
            port = String(model.enginePort)
            discovery.start()
        }
        .onDisappear {
            discovery.stop()
            autoSelectTask?.cancel()
            autoSelectTask = nil
        }
        // Both, not just `engines`: a straggling resolution that fails never changes the
        // list, and `isResolving` going false is the only sign the list has settled.
        .onChange(of: discovery.engines) { _, _ in scheduleAutoSelect() }
        .onChange(of: discovery.isResolving) { _, _ in scheduleAutoSelect() }
    }

    // MARK: Nearby engines

    @ViewBuilder
    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Nearby engines")

            ForEach(discovery.engines) { engine in
                Button { select(engine) } label: { engineRow(engine) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use \(engine.name) at \(engine.address)")
            }

            if discovery.engines.isEmpty && discovery.isBrowsing && discovery.statusText == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(MobileTheme.textTertiary)
                    Text("Searching…").font(MobileTheme.rounded(12)).foregroundStyle(MobileTheme.textTertiary)
                }
                .frame(height: 28)
            }

            if let status = discovery.statusText {
                resultLine("wifi.exclamationmark", status, MobileTheme.warn)
            }
            if let autoSelected {
                resultLine("checkmark.circle.fill", "Using \(autoSelected) — the only engine on this network.", MobileTheme.ok)
            }
        }
    }

    private func engineRow(_ engine: DiscoveredEngine) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MobileTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.name)
                    .font(MobileTheme.rounded(14, .semibold))
                    .foregroundStyle(MobileTheme.textPrimary)
                    .lineLimit(1)
                Text(engine.version.map { "\(engine.address) · \($0)" } ?? engine.address)
                    .font(MobileTheme.rounded(11).monospacedDigit())
                    .foregroundStyle(MobileTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.textTertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(MobileTheme.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(MobileTheme.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Picking a discovered engine is the whole point of the screen, so it saves and
    /// leaves rather than only filling the fields in and waiting for "Save".
    private func select(_ engine: DiscoveredEngine) {
        host = engine.host
        port = String(engine.port)
        model.setEngine(host: engine.host, port: engine.port)
        dismiss()
    }

    /// Waits for the list to stop moving before considering an automatic pick. Two Macs
    /// rarely resolve in the same instant, and acting on the first one to land would save
    /// it and then claim it was "the only engine on this network" next to a second row.
    private func scheduleAutoSelect() {
        guard !didAutoSelect else { return }
        autoSelectTask?.cancel()
        autoSelectTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            autoSelectLoneEngine()
        }
    }

    /// With nothing configured, nothing typed and exactly one engine on the network there
    /// is no choice to make, so make it — once, and visibly. The sheet stays open: the
    /// user opened it on purpose and may want the manual fields anyway.
    ///
    /// The typing and testing guards matter as much as the configured one: a discovery
    /// result can land at any moment, and silently overwriting a half-typed address (or
    /// the address someone is in the middle of testing) is worse than not helping at all.
    private func autoSelectLoneEngine() {
        guard !didAutoSelect,
              !discovery.isResolving,
              model.engineHost.isEmpty,
              host.trimmingCharacters(in: .whitespaces).isEmpty,
              !testing,
              discovery.engines.count == 1,
              let engine = discovery.engines.first else { return }
        didAutoSelect = true
        host = engine.host
        port = String(engine.port)
        model.setEngine(host: engine.host, port: engine.port)
        autoSelected = engine.name
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(MobileTheme.rounded(12, .semibold))
            .foregroundStyle(MobileTheme.textTertiary)
    }

    private func field(title: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MobileTheme.rounded(12, .semibold))
                .foregroundStyle(MobileTheme.textTertiary)
            TextField("", text: text,
                      prompt: Text(placeholder).foregroundColor(MobileTheme.textTertiary))
                .font(MobileTheme.rounded(15).monospacedDigit())
                .foregroundStyle(MobileTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(MobileTheme.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MobileTheme.stroke, lineWidth: 1))
        }
    }

    private func resultLine(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(text).font(MobileTheme.rounded(12)).foregroundStyle(MobileTheme.textSecondary)
        }
    }

    /// Probes the address in the fields without committing it, so a typo can be corrected
    /// before it replaces a working setting.
    @MainActor
    private func test() {
        let address = self.address
        guard !address.host.isEmpty else { return }
        let literal = address.host.contains(":") ? "[\(address.host)]" : address.host
        guard let url = URL(string: "http://\(literal):\(address.port)") else {
            testResult = .failed("That host does not look like an address.")
            return
        }
        testing = true
        testResult = .none
        Task {
            // `disposable`: this client exists only for the tap, so its URLSession is
            // finished afterwards instead of being left behind on every test.
            let result = await MobileModel.probe(
                AceStreamAPI(baseURL: url, pid: MobileModel.clientPID), disposable: true)
            testing = false
            switch result {
            case .success(let version): testResult = .ok(version)
            case .failure(let error): testResult = .failed(error.localizedDescription)
            }
        }
    }
}
