import Foundation
import Network

/// Owns the opt-in "share the engine with my iPhone" feature: the extra LAN
/// listener on the vsock proxy plus a Bonjour advertisement so the companion app
/// can find this Mac without anyone typing an IP address.
///
/// The advertisement is published by an `NWListener` on its own ephemeral port —
/// the engine port itself is already bound by `VsockProxy`, and two listeners
/// cannot share it. The engine's real port therefore travels in the TXT record as
/// `port`, which is what a client should connect to; the SRV port only keeps the
/// record alive.
@MainActor
final class LanSharing {
    /// The port `VsockProxy` bridges to the guest engine.
    static let enginePort: UInt16 = 6878
    static let serviceType = "_kakaplayer._tcp"

    private let log: (String) -> Void
    private var listener: NWListener?
    private weak var proxy: VsockProxy?

    private(set) var isSharing = false

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// `host:port` for the UI, or nil when this Mac has no usable LAN address.
    var address: String? {
        Self.currentLANAddresses().first.map { "\($0):\(Self.enginePort)" }
    }

    /// Opens the LAN listener and starts advertising. Throws (leaving nothing
    /// running) if the listener cannot bind.
    func start(proxy: VsockProxy, engineVersion: String) throws {
        guard !isSharing else { return }
        try proxy.startLAN()
        self.proxy = proxy
        isSharing = true
        advertise(engineVersion: engineVersion)
    }

    /// Stops advertising and closes the LAN listener. Safe to call when off.
    func stop() {
        listener?.cancel()
        listener = nil
        proxy?.stopLAN()
        proxy = nil
        guard isSharing else { return }
        isSharing = false
        log("[lan] stopped advertising \(Self.serviceType)")
    }

    // MARK: Bonjour

    private func advertise(engineVersion: String) {
        listener?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            // Sharing still works, it just has to be reached by IP address.
            log("[lan] could not advertise over Bonjour: \(error.localizedDescription)")
            return
        }
        let txt = NWTXTRecord([
            "app": "KakaPlayer",
            "version": engineVersion,
            "port": String(Self.enginePort),
        ])
        listener.service = NWListener.Service(name: Self.serviceName(), type: Self.serviceType, txtRecord: txt)
        // Nothing is served here; the real traffic goes to the proxy's LAN port.
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleListenerState(state) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            log("[lan] advertising \(Self.serviceName()) as \(Self.serviceType) (engine on port \(Self.enginePort))")
        case .failed(let error):
            log("[lan] Bonjour advertisement failed: \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
        default:
            break
        }
    }

    /// Bonjour instance names are limited to 63 UTF-8 bytes.
    static func serviceName() -> String {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let name = "KakaPlayer on \(host)"
        guard name.utf8.count > 63 else { return name }
        return String(decoding: name.utf8.prefix(60), as: UTF8.self) + "…"
    }

    // MARK: Interface addresses

    /// Every usable IPv4 address of this Mac, loopback and link-local excluded,
    /// Wi-Fi/Ethernet (en0, en1) first so the displayed address is the one a phone
    /// on the same Wi-Fi can actually reach.
    nonisolated static func currentLANAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var found: [(interface: String, ip: String)] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            guard !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") else { continue }
            found.append((String(cString: entry.pointee.ifa_name), ip))
        }

        let preferred = ["en0", "en1"]
        return found.sorted { lhs, rhs in
            let l = preferred.firstIndex(of: lhs.interface) ?? preferred.count
            let r = preferred.firstIndex(of: rhs.interface) ?? preferred.count
            if l != r { return l < r }
            if lhs.interface != rhs.interface { return lhs.interface < rhs.interface }
            return lhs.ip < rhs.ip
        }.map(\.ip)
    }
}
