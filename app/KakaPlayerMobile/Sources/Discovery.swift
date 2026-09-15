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

    /// For display. An IPv6 literal gets the brackets it is always written with, so
    /// "::1" and its port do not run together into "::1:6878".
    var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
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
    /// How long one resolution attempt gets before it is abandoned. A dead advertisement
    /// (a Mac that slept mid-browse) must not leave a spinner behind, and the retry that
    /// drops the IPv4 preference is on the far side of this.
    private static let resolveTimeout = 5

    @Published private(set) var engines: [DiscoveredEngine] = []
    @Published private(set) var isBrowsing = false
    /// True while at least one service is still being resolved to an address. The list is
    /// not settled until this goes false, which is what stops a caller from treating a
    /// half-resolved network as "there is only one engine here".
    @Published private(set) var isResolving = false
    /// A line to show the user when browsing is not simply working: the Local Network
    /// permission prompt was denied, or the browser failed outright. `nil` when fine.
    @Published private(set) var statusText: String?

    /// A resolution in flight: the throwaway connection, plus the deadline that gives up
    /// on it. `NWConnection` has no usable "I will never connect" state of its own (see
    /// `resolverStateChanged`), so the deadline is the only thing that bounds this.
    private struct Resolver {
        let connection: NWConnection
        var deadline: Task<Void, Never>?
    }

    private var browser: NWBrowser?
    /// In-flight resolutions, keyed the same way `engines` are, so a second round of
    /// browse results does not start a duplicate connection for a service already known.
    private var resolvers: [String: Resolver] = [:]
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { FileLog.shared.write($0) }) {
        self.log = log
    }

    deinit {
        browser?.cancel()
        for resolver in resolvers.values {
            resolver.deadline?.cancel()
            resolver.connection.cancel()
        }
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
            let name = Self.displayName(result.endpoint, fallback: key)
            if let index = engines.firstIndex(where: { $0.id == key }) {
                engines[index].version = version          // a re-published TXT record
            } else if resolvers[key] == nil, !engines.contains(where: { $0.name == name }) {
                // The name check keeps the *other* endpoint of a Mac that is visible over
                // two interfaces from being resolved just to be deduplicated away again.
                connect(to: result.endpoint, key: key, name: name, version: version, preferIPv4: true)
            }
        }
    }

    // MARK: Resolution

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
        resolvers[key] = Resolver(connection: connection)
        isResolving = true
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection else { return }
                self.resolverStateChanged(state, connection: connection, endpoint: endpoint,
                                          key: key, name: name, version: version, preferIPv4: preferIPv4)
            }
        }
        // Armed before `start()` so a connection that answers instantly cannot be caught
        // by its own deadline: `finishResolving` cancels whatever is stored here.
        resolvers[key]?.deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.resolveTimeout))
            guard !Task.isCancelled, let self, self.resolvers[key] != nil else { return }
            self.giveUp(on: endpoint, key: key, name: name, version: version,
                        preferIPv4: preferIPv4, reason: "no answer within \(Self.resolveTimeout)s")
        }
        connection.start(queue: .main)
    }

    private func resolverStateChanged(_ state: NWConnection.State, connection: NWConnection,
                                      endpoint: NWEndpoint, key: String, name: String,
                                      version: String?, preferIPv4: Bool) {
        // A late callback from a connection we already tore down must not revive it.
        guard resolvers[key]?.connection === connection else { return }
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
        case .waiting(let error):
            // `.waiting`, not `.failed`, is how an unreachable or refused peer is reported,
            // and the connection sits there retrying — `connectionTimeout` does not promote
            // it. A pinned attempt against an advertiser with no IPv4 address may not even
            // get this far: measured, it simply never leaves `.preparing`, which is why the
            // deadline above exists. Both roads lead to the same fallback.
            if preferIPv4 {
                giveUp(on: endpoint, key: key, name: name, version: version,
                       preferIPv4: true, reason: "\(error)")
            }
            // Unpinned there is nothing better to switch to, and a wait can still come
            // good once an interface finishes coming up, so let the deadline end it.
        case .failed(let error):
            giveUp(on: endpoint, key: key, name: name, version: version,
                   preferIPv4: preferIPv4, reason: "\(error)")
        case .cancelled:
            finishResolving(key)
        default:
            break
        }
    }

    /// Abandons the current attempt: retries without the IPv4 preference if that is what
    /// was in the way, and otherwise drops the service until the browser reports it again.
    private func giveUp(on endpoint: NWEndpoint, key: String, name: String, version: String?,
                        preferIPv4: Bool, reason: String) {
        finishResolving(key)
        if preferIPv4 {
            log("[discovery] \(name) did not answer over IPv4 (\(reason)); retrying without the preference")
            connect(to: endpoint, key: key, name: name, version: version, preferIPv4: false)
        } else {
            log("[discovery] gave up resolving \(name): \(reason)")
        }
    }

    /// Cancels and forgets a resolver — its deadline, and its connection's handler, so the
    /// connection does not keep this object (and itself) alive through the closure.
    private func finishResolving(_ key: String) {
        guard let resolver = resolvers.removeValue(forKey: key) else { return }
        resolver.deadline?.cancel()
        resolver.connection.stateUpdateHandler = nil
        resolver.connection.cancel()
        isResolving = !resolvers.isEmpty
    }

    private func add(_ engine: DiscoveredEngine) {
        // One Mac can be browsed twice — over Wi-Fi and over AWDL — as two endpoints with
        // the same Bonjour instance name and *different* addresses, so the name is what
        // identifies the machine. Collapsing them also keeps "the only engine on this
        // network" from being said next to a two-row list.
        engines.removeAll { $0.id == engine.id || $0.name == engine.name }
        engines.append(engine)
        engines.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Endpoint plumbing

    static func key(for endpoint: NWEndpoint) -> String { String(describing: endpoint) }

    /// The Bonjour instance name, which is also how one machine found over two interfaces
    /// is recognised as one machine.
    static func displayName(_ endpoint: NWEndpoint, fallback: String) -> String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return fallback
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
