import Foundation
import dnssd

/// Owns the opt-in "share the engine with my iPhone" feature: the extra LAN
/// listener on the vsock proxy plus a Bonjour advertisement so the companion app
/// can find this Mac without anyone typing an IP address.
///
/// The advertisement goes through `DNSServiceRegister` rather than an `NWListener`
/// because it registers the SRV record without binding a socket of its own. The
/// advertised port is therefore the real engine port — `VsockProxy` already holds
/// 6878, and an `NWListener` would have had to publish some other, useless port.
/// A client can connect straight to the resolved service endpoint.
@MainActor
final class LanSharing {
    /// The port `VsockProxy` bridges to the guest engine. `nonisolated` because the
    /// C registration callback, which is not on any actor, reports against them.
    nonisolated static let enginePort: UInt16 = 6878
    nonisolated static let serviceType = "_kakaplayer._tcp"

    private let log: (String) -> Void
    private weak var proxy: VsockProxy?
    private var serviceRef: DNSServiceRef?
    /// Retained for as long as the registration lives; see `AdvertisementContext`.
    private var contextPointer: UnsafeMutableRawPointer?

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
        withdrawAdvertisement()
        proxy?.stopLAN()
        proxy = nil
        guard isSharing else { return }
        isSharing = false
        log("[lan] stopped advertising \(Self.serviceType)")
    }

    // MARK: Bonjour

    private func advertise(engineVersion: String) {
        withdrawAdvertisement()
        let box = AdvertisementContext(log: log)
        let context = Unmanaged.passRetained(box).toOpaque()
        let txt = Self.txtRecord(engineVersion: engineVersion)

        var ref: DNSServiceRef?
        let status = txt.withUnsafeBytes { raw in
            DNSServiceRegister(
                &ref,
                0,                                  // no flags: let mDNSResponder rename on conflict
                UInt32(kDNSServiceInterfaceIndexAny),
                Self.serviceName(),
                Self.serviceType,
                nil,                                // default domain (local.)
                nil,                                // this host
                Self.enginePort.bigEndian,          // DNSServiceRegister wants network byte order
                UInt16(raw.count),
                raw.baseAddress,
                lanSharingRegisterReply,
                context)
        }
        guard status == kDNSServiceErr_NoError, let ref else {
            Unmanaged<AdvertisementContext>.fromOpaque(context).release()
            // Sharing still works, it just has to be reached by IP address.
            log("[lan] could not advertise over Bonjour (DNSServiceRegister error \(status)); the engine is still reachable at \(address ?? "this Mac's LAN address")")
            return
        }
        // Callbacks arrive on the main queue, which is also where `stop()` runs —
        // DNSServiceRefDeallocate has to be called from the queue it was set on.
        let queued = DNSServiceSetDispatchQueue(ref, DispatchQueue.main)
        guard queued == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(ref)
            Unmanaged<AdvertisementContext>.fromOpaque(context).release()
            log("[lan] could not schedule the Bonjour registration (error \(queued))")
            return
        }
        serviceRef = ref
        contextPointer = context
    }

    private func withdrawAdvertisement() {
        if let serviceRef {
            // Also guarantees no further callbacks, so releasing the box below is safe.
            DNSServiceRefDeallocate(serviceRef)
            self.serviceRef = nil
        }
        if let contextPointer {
            Unmanaged<AdvertisementContext>.fromOpaque(contextPointer).release()
            self.contextPointer = nil
        }
    }

    /// A DNS-SD TXT record is a sequence of length-prefixed `key=value` strings,
    /// each at most 255 bytes. `port` is redundant now that the SRV record carries
    /// the real port, but it is cheap and keeps older clients working.
    static func txtRecord(engineVersion: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for entry in ["app=KakaPlayer", "version=\(engineVersion)", "port=\(enginePort)"] {
            let utf8 = Array(entry.utf8)
            guard !utf8.isEmpty, utf8.count <= 255 else { continue }
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        return bytes
    }

    /// Bonjour instance names are limited to 63 UTF-8 bytes. Trim whole characters
    /// so a multi-byte scalar never gets cut in half; "…" costs 3 bytes, so the
    /// trimmed stem has to fit in 60.
    static func serviceName() -> String {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var name = "KakaPlayer on \(host)"
        guard name.utf8.count > 63 else { return name }
        while name.utf8.count > 60, !name.isEmpty { name.removeLast() }
        return name + "…"
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

/// What the C registration callback is allowed to touch. A C function pointer
/// can't capture context, so the box is passed through DNS-SD's `context` and kept
/// retained for exactly as long as the registration lives — a late callback can
/// never reach a deallocated object.
private final class AdvertisementContext {
    let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }
}

/// Reports the name the service ended up registered under, which is not
/// necessarily the requested one: without `kDNSServiceFlagsNoAutoRename`,
/// mDNSResponder appends a counter when the name is already taken on the network.
private func lanSharingRegisterReply(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ errorCode: DNSServiceErrorType,
    _ name: UnsafePointer<CChar>?,
    _ regtype: UnsafePointer<CChar>?,
    _ domain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<AdvertisementContext>.fromOpaque(context).takeUnretainedValue()
    guard errorCode == kDNSServiceErr_NoError else {
        box.log("[lan] Bonjour registration failed (error \(errorCode))")
        return
    }
    let registered = name.map { String(cString: $0) } ?? "KakaPlayer"
    box.log("[lan] advertising \(registered) as \(LanSharing.serviceType) on port \(LanSharing.enginePort)")
}
