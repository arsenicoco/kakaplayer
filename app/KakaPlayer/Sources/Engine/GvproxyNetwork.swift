import Foundation

/// User-space networking for the guest via gvproxy (github.com/containers/gvisor-tap-vsock).
///
/// macOS's built-in NAT for Virtualization.framework depends on the system DHCP server and
/// breaks under VPNs; gvproxy instead receives raw Ethernet frames from the VM over a unix
/// datagram socket and makes ordinary host connections. The guest gets 192.168.127.2/24 with
/// gateway + DNS at 192.168.127.1 (gvproxy's fixed layout for the MAC below).
final class GvproxyNetwork {
    static let guestMAC = "5a:94:ef:e4:0c:ee"
    static let guestIP = "192.168.127.2/24"
    static let gateway = "192.168.127.1"

    private let process = Process()
    private let dir: URL
    private var socketFD: Int32 = -1
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
        // unixgram paths must stay under 104 bytes.
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kaka-\(getpid())", isDirectory: true)
    }

    /// Launches gvproxy and returns a connected datagram socket handle for
    /// VZFileHandleNetworkDeviceAttachment.
    func start() throws -> FileHandle {
        guard let exe = Bundle.main.url(forResource: "gvproxy", withExtension: nil) else {
            throw NSError(domain: "KakaPlayer", code: 20, userInfo: [NSLocalizedDescriptionKey: "gvproxy is missing from the app bundle."])
        }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vfkitSock = dir.appendingPathComponent("gv.sock").path
        let apiSock = dir.appendingPathComponent("api.sock").path
        let localSock = dir.appendingPathComponent("vm.sock").path

        process.executableURL = exe
        process.arguments = ["-listen-vfkit", "unixgram://\(vfkitSock)", "-listen", "unix://\(apiSock)", "-mtu", "1500"]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") where !line.isEmpty { self?.log("[gvproxy] \(line)") }
        }
        try process.run()

        // Wait for gvproxy to create its socket.
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: vfkitSock) {
            if Date() > deadline || !process.isRunning {
                throw NSError(domain: "KakaPlayer", code: 21, userInfo: [NSLocalizedDescriptionKey: "gvproxy did not start (see log)."])
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var local = sockaddr_un(); local.sun_family = sa_family_t(AF_UNIX)
        var remote = sockaddr_un(); remote.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &local.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, localSock, 104) } }
        _ = withUnsafeMutablePointer(to: &remote.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, vfkitSock, 104) } }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        unlink(localSock)
        let b = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard b == 0 else { let e = errno; close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(e), userInfo: [NSLocalizedDescriptionKey: "bind \(localSock): \(String(cString: strerror(e)))"]) }
        let c = withUnsafePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
        guard c == 0 else { let e = errno; close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(e), userInfo: [NSLocalizedDescriptionKey: "connect \(vfkitSock): \(String(cString: strerror(e)))"]) }
        var snd: Int32 = 1 << 20, rcv: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        socketFD = fd
        log("[gvproxy] started (pid \(process.processIdentifier)), guest \(Self.guestIP) via \(Self.gateway)")
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    func stop() {
        if process.isRunning { process.terminate() }
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        try? FileManager.default.removeItem(at: dir)
    }

    deinit { stop() }
}
