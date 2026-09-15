import Foundation
@preconcurrency import Virtualization

/// Listens on 127.0.0.1:hostPort and forwards each TCP connection to a vsock
/// port inside the guest, where socat bridges it to the engine's HTTP port.
///
/// An optional second listener on 0.0.0.0:hostPort can be started and stopped at
/// runtime (see `startLAN()`), so an iPhone or iPad on the same Wi-Fi can reach the
/// engine. It only accepts peers on a private network; see `isPrivateIPv4(_:)`.
/// The loopback listener is never affected by it: when both are bound, the kernel
/// routes 127.0.0.1 connections to the more specific loopback socket.
final class VsockProxy {
    let hostPort: UInt16
    let guestPort: UInt32
    private let vm: VMController
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let log: (String) -> Void
    private var lastFailureLog = Date.distantPast
    private let failureLogLock = NSLock()

    /// Guards `lanFD` and `rejectedPeers`, which the LAN accept thread and the
    /// main thread both touch.
    private let lanLock = NSLock()
    private var lanFD: Int32 = -1
    private var lanAcceptThread: Thread?
    /// Peer addresses already refused, so each one is logged only once.
    private var rejectedPeers = Set<String>()

    init(hostPort: UInt16, guestPort: UInt32, vm: VMController, log: @escaping (String) -> Void) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.vm = vm
        self.log = log
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = hostPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else {
            let e = errno; close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e),
                          userInfo: [NSLocalizedDescriptionKey: "Cannot bind 127.0.0.1:\(hostPort) (\(String(cString: strerror(e)))). Is another Ace Stream engine running?"])
        }
        guard listen(fd, 16) == 0 else {
            let e = errno; close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "vsock-proxy-accept"
        t.start()
        acceptThread = t
        log("[proxy] listening on 127.0.0.1:\(hostPort) -> vsock:\(guestPort)")
    }

    func stop() {
        stopLAN()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    // MARK: LAN listener

    /// True while the 0.0.0.0 listener is up.
    var isLANListening: Bool {
        lanLock.lock(); defer { lanLock.unlock() }
        return lanFD >= 0
    }

    /// Binds a second listener on every interface. Idempotent; the loopback
    /// listener keeps running untouched.
    func startLAN() throws {
        lanLock.lock()
        let already = lanFD >= 0
        lanLock.unlock()
        guard !already else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        // Required so the wildcard bind can coexist with the loopback listener.
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = hostPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else {
            let e = errno; close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e),
                          userInfo: [NSLocalizedDescriptionKey: "Cannot bind 0.0.0.0:\(hostPort) (\(String(cString: strerror(e))))."])
        }
        guard listen(fd, 16) == 0 else {
            let e = errno; close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
        lanLock.lock()
        lanFD = fd
        rejectedPeers.removeAll()
        lanLock.unlock()
        let t = Thread { [weak self] in self?.lanAcceptLoop() }
        t.name = "vsock-proxy-lan-accept"
        t.start()
        lanAcceptThread = t
        log("[proxy] sharing on 0.0.0.0:\(hostPort) -> vsock:\(guestPort) (private networks only)")
    }

    /// Tears the LAN listener down. In-flight bridged connections are left alone.
    func stopLAN() {
        lanLock.lock()
        let fd = lanFD
        lanFD = -1
        rejectedPeers.removeAll()
        lanLock.unlock()
        guard fd >= 0 else { return }
        // Closing the descriptor is what makes the blocked accept() return; shutdown()
        // on a listening socket is a no-op on macOS. The accept loop then sees
        // `lanFD < 0` and exits.
        close(fd)
        lanAcceptThread = nil
        log("[proxy] stopped sharing on 0.0.0.0:\(hostPort)")
    }

    private func lanAcceptLoop() {
        while true {
            lanLock.lock()
            let fd = lanFD
            lanLock.unlock()
            guard fd >= 0 else { return }

            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED:
                    continue   // the client gave up before we got to it
                case EMFILE, ENFILE:
                    // Out of descriptors: back off instead of spinning on the error.
                    usleep(100_000)
                    continue
                default:
                    return
                }
            }
            // Ask the kernel for the peer rather than trusting the address accept()
            // filled in, and drop anything that is not on a private network.
            let peer = Self.peerIPv4(of: client)
            guard let peer, Self.isPrivateIPv4(peer) else {
                noteRejection(peer.map(Self.describe) ?? "unknown address")
                close(client)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread { [weak self] in self?.handle(client: client) }
            t.name = "vsock-proxy-lan-conn"
            t.start()
        }
    }

    private func noteRejection(_ peer: String) {
        lanLock.lock()
        let isNew = rejectedPeers.insert(peer).inserted
        // Don't let a scanner grow the set without bound.
        if rejectedPeers.count > 256 { rejectedPeers.removeAll() }
        lanLock.unlock()
        if isNew { log("[proxy] refused connection from non-private address \(peer)") }
    }

    /// The connected peer's IPv4 address, or nil if it has none (the socket is
    /// AF_INET, so anything else is refused).
    static func peerIPv4(of fd: Int32) -> in_addr? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        guard result == 0, storage.ss_family == sa_family_t(AF_INET) else { return nil }
        return withUnsafePointer(to: &storage) { ptr in
            ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
    }

    /// RFC 1918 (10/8, 172.16/12, 192.168/16), link-local 169.254/16 and loopback
    /// 127/8. Everything else — including CGNAT 100.64/10 and any routable
    /// address — is refused.
    static func isPrivateIPv4(_ address: in_addr) -> Bool {
        let host = UInt32(bigEndian: address.s_addr)
        switch host >> 24 {
        case 10, 127: return true
        default: break
        }
        if host & 0xFFF0_0000 == 0xAC10_0000 { return true }   // 172.16.0.0/12
        if host >> 16 == 0xC0A8 { return true }                // 192.168.0.0/16
        if host >> 16 == 0xA9FE { return true }                // 169.254.0.0/16
        return false
    }

    static func describe(_ address: in_addr) -> String {
        var value = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "?" }
        return String(cString: buffer)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &len) }
            }
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread { [weak self] in self?.handle(client: client) }
            t.name = "vsock-proxy-conn"
            t.start()
        }
    }

    private func handle(client: Int32) {
        let conn: VZVirtioSocketConnection
        do {
            conn = try vm.connectVsock(port: guestPort)
        } catch {
            // The engine takes a while to come up; log at most one failure every 5 s.
            failureLogLock.lock()
            let shouldLog = Date().timeIntervalSince(lastFailureLog) > 5
            if shouldLog { lastFailureLog = Date() }
            failureLogLock.unlock()
            if shouldLog { log("[proxy] vsock connect failed (engine not up yet?): \(error.localizedDescription)") }
            close(client)
            return
        }
        let guest = conn.fileDescriptor
        var one: Int32 = 1
        setsockopt(guest, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let group = DispatchGroup()
        group.enter()
        let t1 = Thread { Self.pump(from: client, to: guest); group.leave() }
        t1.name = "proxy c->g"; t1.start()
        group.enter()
        let t2 = Thread { Self.pump(from: guest, to: client); group.leave() }
        t2.name = "proxy g->c"; t2.start()
        group.wait()
        close(client)
        conn.close()
    }

    private static func pump(from src: Int32, to dst: Int32) {
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = read(src, buf, bufSize)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            var off = 0
            while off < n {
                let w = write(dst, buf + off, n - off)
                if w < 0 && errno == EINTR { continue }
                if w <= 0 { shutdown(src, SHUT_RD); return }
                off += w
            }
        }
        shutdown(dst, SHUT_WR)
    }
}
