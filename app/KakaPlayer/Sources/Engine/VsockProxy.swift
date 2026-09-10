import Foundation
@preconcurrency import Virtualization

/// Listens on 127.0.0.1:hostPort and forwards each TCP connection to a vsock
/// port inside the guest, where socat bridges it to the engine's HTTP port.
final class VsockProxy {
    let hostPort: UInt16
    let guestPort: UInt32
    private let vm: VMController
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let log: (String) -> Void
    private var lastFailureLog = Date.distantPast
    private let failureLogLock = NSLock()

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
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
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
