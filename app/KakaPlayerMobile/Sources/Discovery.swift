import Foundation
import Network

/// One engine found on the local network, already resolved to something the app can
/// actually connect to.
struct DiscoveredEngine: Identifiable, Equatable {
    /// The browse result's endpoint description — stable for as long as the service is
    /// advertised, and unique per instance name.
    let id: String
    /// The Bonjour instance name, e.g. "KakaPlayer on Arseniy's MacBook Pro".
    let name: String
    /// An IPv4 literal when one is available, otherwise the `.local` hostname.
    let host: String
    let port: Int
    /// `version` from the TXT record, when the advertiser published one. The advertiser
    /// can republish it (the Mac does, when its engine updates) without the service
    /// itself changing, so this is the one part of an entry that is refreshed in place.
    fileprivate(set) var version: String?

    var address: String { "\(host):\(port)" }
}

/// Browses for `_kakaplayer._tcp` and resolves every hit to a concrete `host:port`, so
/// Settings can offer the Mac's engine without anyone reading an IP address off a screen.
///
/// The Mac (see `LanSharing`) registers the service on the *real* engine port, so the
/// resolved SRV port is the port to talk to — there is no separate handshake, and the TXT
/// record is only read for the engine version we show next to the name.
///
/// Resolution is done by opening an `NWConnection` to the service endpoint and reading
/// the path's `remoteEndpoint` once it is ready: `NWBrowser` hands out an opaque
/// `.service` endpoint, and `URLSession` cannot be pointed at one of those.
@MainActor
final class EngineDiscovery: ObservableObject {

    static let serviceType = "_kakaplayer._tcp"
    /// A dead advertisement (a Mac that slept mid-browse) must not leave a spinner behind.
    private static let resolveTimeout = 5

    @Published private(set) var engines: [DiscoveredEngine] = []
    @Published private(set) var isBrowsing = false
    /// A line to show the user when browsing is not simply working: the Local Network
    /// permission prompt was denied, or the browser failed outright. `nil` when fine.
    @Published private(set) var statusText: String?

    private var browser: NWBrowser?
    /// In-flight resolutions, keyed the same way `engines` are, so a second round of
    /// browse results does not start a duplicate connection for a service already known.
    private var resolvers: [String: NWConnection] = [:]
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { FileLog.shared.write($0) }) {
        self.log = log
    }

    deinit {
        browser?.cancel()
        for connection in resolvers.values { connection.cancel() }
    }

    // MARK: Browsing

    /// Starts browsing. Calling it again while a browser is live does nothing, so it is
    /// safe to drive straight from `onAppear`.
    func start() {
        guard browser == nil else { return }
        // `bonjourWithTXTRecord`, not `bonjour`: the plain descriptor never delivers a TXT
        // record, so every result would arrive with `.none` metadata and no engine version.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        // Callbacks are hopped onto the main actor, so a browser that was cancelled in the
        // meantime can still have one in flight; ignore anything from a retired browser
        // rather than let it switch `isBrowsing` off under a newer one.
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                self.browserStateChanged(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                self.browseResultsChanged(results)
            }
        }
        self.browser = browser
        isBrowsing = true
        statusText = nil
        log("[discovery] browsing for \(Self.serviceType)")
        browser.start(queue: .main)
    }

    /// Stops browsing and drops any resolution still in flight. Idempotent.
    ///
    /// Already-discovered engines are left in place: the view that owns this object is
    /// recreated per presentation anyway, and clearing here would only blank the list
    /// while the sheet animates away.
    func stop() {
        guard browser != nil || !resolvers.isEmpty else { return }
        browser?.cancel()
        browser = nil
        for key in Array(resolvers.keys) { finishResolving(key) }
        isBrowsing = false
        log("[discovery] stopped browsing")
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            isBrowsing = true
            statusText = nil
        case .waiting(let error):
            // A denied Local Network permission surfaces here rather than as a failure,
            // and it never resolves on its own — say what to do about it.
            isBrowsing = true
            statusText = "Waiting for the local network. If you declined the Local Network prompt, turn KakaPlayer back on in Settings › Privacy & Security › Local Network."
            log("[discovery] browser waiting: \(error)")
        case .failed(let error):
            isBrowsing = false
            statusText = "Could not search the local network: \(error.localizedDescription)"
            log("[discovery] browser failed: \(error)")
            browser?.cancel()
            browser = nil
        default:
            // Including `.cancelled`: the only cancels come from `stop()` and from the
            // failure above, both of which have already settled `isBrowsing`.
            break
        }
    }

    private func browseResultsChanged(_ results: Set<NWBrowser.Result>) {
        let live = Dictionary(results.map { (Self.key(for: $0.endpoint), $0) }, uniquingKeysWith: { a, _ in a })

        // Drop what went away, including resolutions that will never be needed now.
        engines.removeAll { live[$0.id] == nil }
        for key in Array(resolvers.keys) where live[key] == nil { finishResolving(key) }

        for (key, result) in live {
            let version = Self.txtValue("version", from: result.metadata)
            if let index = engines.firstIndex(where: { $0.id == key }) {
                engines[index].version = version          // a re-published TXT record
            } else if resolvers[key] == nil {
                resolve(result, key: key, version: version)
            }
        }
    }

    // MARK: Resolution

    private func resolve(_ result: NWBrowser.Result, key: String, version: String?) {
        let name = Self.serviceName(result.endpoint) ?? key
        connect(to: result.endpoint, key: key, name: name, version: version, preferIPv4: true)
    }

    /// Opens a throwaway connection purely to learn the address behind the service.
    ///
    /// The first attempt pins the stack to IPv4 so the phone ends up with the address a
    /// user would recognise (and one that survives being typed back into the manual
    /// fields); if the advertiser has no IPv4 route, the retry takes whatever the
    /// resolver offers — an IPv6 address or the bare `.local` hostname.
    private func connect(to endpoint: NWEndpoint, key: String, name: String, version: String?, preferIPv4: Bool) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?
            .connectionTimeout = Self.resolveTimeout
        if preferIPv4 {
            (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        resolvers[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection else { return }
                self.resolverStateChanged(state, connection: connection, endpoint: endpoint,
                                          key: key, name: name, version: version, preferIPv4: preferIPv4)
            }
        }
        connection.start(queue: .main)
    }

    private func resolverStateChanged(_ state: NWConnection.State, connection: NWConnection,
                                      endpoint: NWEndpoint, key: String, name: String,
                                      version: String?, preferIPv4: Bool) {
        // A late callback from a connection we already tore down must not revive it.
        guard resolvers[key] === connection else { return }
        switch state {
        case .ready:
            let remote = connection.currentPath?.remoteEndpoint
            finishResolving(key)
            guard case .hostPort(let host, let port)? = remote, let address = Self.hostString(host) else {
                log("[discovery] \(name) resolved to an address we cannot use (\(String(describing: remote)))")
                return
            }
            add(DiscoveredEngine(id: key, name: name, host: address, port: Int(port.rawValue), version: version))
            log("[discovery] \(name) at \(address):\(port.rawValue)\(version.map { " version \($0)" } ?? "")")
        case .waiting:
            // No route to the advertiser yet. `connectionTimeout` turns a hopeless wait
            // into `.failed`, so there is nothing to do but let it run out.
            break
        case .failed(let error):
            finishResolving(key)
            if preferIPv4 {
                connect(to: endpoint, key: key, name: name, version: version, preferIPv4: false)
            } else {
                log("[discovery] could not resolve \(name): \(error)")
            }
        case .cancelled:
            finishResolving(key)
        default:
            break
        }
    }

    /// Cancels and forgets a resolver, clearing its handler so the connection does not
    /// keep this object (and itself) alive through the closure.
    private func finishResolving(_ key: String) {
        guard let connection = resolvers.removeValue(forKey: key) else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func add(_ engine: DiscoveredEngine) {
        // The same Mac reached over two interfaces resolves to the same address twice;
        // show it once.
        engines.removeAll { $0.id == engine.id || ($0.host == engine.host && $0.port == engine.port) }
        engines.append(engine)
        engines.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Endpoint plumbing

    static func key(for endpoint: NWEndpoint) -> String { String(describing: endpoint) }

    static func serviceName(_ endpoint: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = endpoint { return name }
        return nil
    }

    static func txtValue(_ key: String, from metadata: NWBrowser.Result.Metadata) -> String? {
        guard case .bonjour(let txt) = metadata else { return nil }
        guard let value = txt[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    /// Turns the resolved host into something `MobileModel.engineURL` can spell.
    ///
    /// A link-local IPv6 address is deliberately rejected: it is only routable *with* its
    /// interface zone, and a zone cannot survive the trip through `URL`. The caller is
    /// better off retrying without the IPv4 preference and landing on the `.local` name.
    static func hostString(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return withoutZone(String(describing: address))
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return withoutZone(String(describing: mapped)) }
            guard !address.isLinkLocal else { return nil }
            return withoutZone(String(describing: address))
        case .name(let name, _):
            // "mac.local." — the trailing root dot is correct DNS and ugly everywhere else.
            let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
            return trimmed.isEmpty ? nil : trimmed
        @unknown default:
            return nil
        }
    }

    /// An address resolved over a specific interface describes itself with that interface
    /// attached — "192.168.68.238%en0". `URL(string:)` returns nil for a host spelled that
    /// way, so the engine would silently never be reachable; the address on its own is
    /// what the user recognises and what the manual field expects.
    static func withoutZone(_ address: String) -> String {
        guard let percent = address.firstIndex(of: "%") else { return address }
        return String(address[..<percent])
    }
}
