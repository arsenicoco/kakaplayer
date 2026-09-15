import Foundation

/// Serves the engine's MPEG-TS stream to the player over a local HTTP URL while keeping
/// exactly ONE upstream connection to the engine. The Ace Stream engine supports a single
/// reader per playback session and answers any concurrent reader with a broken
/// "200 + 500 failed to seek" reply; libvlc, however, opens the same URL more than once
/// (probing, reconnects). Fanning out from one upstream connection sidesteps that.
final class StreamRelay: NSObject, URLSessionDataDelegate {
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    private var upstreamURL: URL?                // guarded by `lock`
    private var clients: [Client] = []
    private var recent = Data()                  // last ~1.5 MB, sent first to late joiners
    private let recentLimit = 1_500_000
    private var stopped = false
    private let log: (String) -> Void
    /// Called (on an arbitrary thread) when the upstream connection ends or fails.
    var onUpstreamEnded: ((Error?) -> Void)?

    private final class Client {
        let fd: Int32
        let queue = DispatchQueue(label: "dev.kakaplayer.relay.client")
        var pending = 0
        var closed = false
        init(fd: Int32) { self.fd = fd }
    }

    init(log: @escaping (String) -> Void) {
        self.log = log
        super.init()
    }

    var localURL: URL { URL(string: "http://127.0.0.1:\(port)/live.ts")! }

    func start(upstream: URL) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        guard b == 0, listen(fd, 8) == 0 else { let e = errno; close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(e)) }
        var bound = sockaddr_in(); var blen = len
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &blen) } }
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "relay-accept"; t.start()

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = .infinity
        cfg.waitsForConnectivity = false
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        lock.lock(); upstreamURL = upstream; lock.unlock()
        var req = URLRequest(url: upstream)
        req.setValue("KakaPlayer", forHTTPHeaderField: "User-Agent")
        let task = s.dataTask(with: req)
        self.task = task
        task.resume()
        log("[relay] serving \(localURL.absoluteString) from \(upstream.absoluteString)")
    }

    func stop() {
        lock.lock()
        stopped = true
        let cs = clients; clients = []
        lock.unlock()
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        for c in cs { closeClient(c) }
    }

    // MARK: clients

    private func acceptLoop() {
        while listenFD >= 0 {
            var a = sockaddr_in(); var l = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &l) } }
            if fd < 0 { if errno == EINTR { continue }; return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread { [weak self] in self?.handle(fd: fd) }
            t.name = "relay-client"; t.start()
        }
    }

    private func handle(fd: Int32) {
        // Read the request head (we don't care about its contents).
        var head = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while head.count < 16384 {
            let n = read(fd, buf, 4096)
            if n <= 0 { close(fd); return }
            head.append(buf, count: n)
            if head.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        let requestLine = String(data: head.prefix(while: { $0 != 0x0A }), encoding: .utf8) ?? ""
        let isHead = requestLine.hasPrefix("HEAD ")
        let response = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-cache\r\nAccept-Ranges: none\r\nConnection: close\r\n\r\n"
        _ = response.withCString { write(fd, $0, strlen($0)) }
        if isHead { close(fd); return }

        let client = Client(fd: fd)
        lock.lock()
        if stopped { lock.unlock(); close(fd); return }
        clients.append(client)
        let preroll = recent
        lock.unlock()
        log("[relay] player connected (\(requestLine.trimmingCharacters(in: .whitespacesAndNewlines))), preroll \(preroll.count) bytes")
        if !preroll.isEmpty { send(preroll, to: client) }
    }

    private func send(_ data: Data, to client: Client) {
        client.queue.async { [weak self] in
            guard !client.closed else { return }
            let ok = data.withUnsafeBytes { raw -> Bool in
                var off = 0
                while off < raw.count {
                    let w = write(client.fd, raw.baseAddress! + off, raw.count - off)
                    if w < 0 && errno == EINTR { continue }
                    if w <= 0 { return false }
                    off += w
                }
                return true
            }
            client.pending -= data.count
            if !ok { self?.drop(client) }
        }
    }

    private func drop(_ client: Client) {
        lock.lock()
        clients.removeAll { $0 === client }
        lock.unlock()
        closeClient(client)
        log("[relay] player disconnected")
    }

    private func closeClient(_ client: Client) {
        if !client.closed {
            client.closed = true
            shutdown(client.fd, SHUT_RDWR)
            close(client.fd)
        }
    }

    // MARK: upstream

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            log("[relay] upstream answered HTTP \(http.statusCode)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        recent.append(data)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        let cs = clients
        lock.unlock()
        for c in cs {
            if c.pending > 32_000_000 { drop(c); continue }   // stalled player
            c.pending += data.count
            send(data, to: c)
        }
    }

    /// The engine answers `/ace/r/...` with a 302 to `/content/...` built from its own
    /// loopback address. A client on another device that followed that literally would
    /// land on its *own* loopback, so keep the redirect on the host we dialled. Redirects
    /// that are already off-loopback, or that we cannot rebuild, are followed unchanged.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); let upstream = upstreamURL; lock.unlock()
        // A loopback upstream is the engine-on-this-Mac case: nothing to retarget.
        guard let upstream, !LoopbackRewrite.isLoopback(upstream.host), let url = request.url else {
            completionHandler(request)
            return
        }
        guard let retargeted = LoopbackRewrite.retargeted(url, to: upstream) else {
            // Redirects that already point off-loopback are ordinary; a loopback one we
            // failed to rebuild is not, and would send us to our own loopback.
            if LoopbackRewrite.isLoopback(url.host) {
                log("[relay] could not retarget redirect \(url.absoluteString) at \(upstream.host ?? "?"), following as-is")
            }
            completionHandler(request)
            return
        }
        var rewritten = request
        rewritten.url = retargeted
        log("[relay] redirect to \(url.absoluteString) retargeted at \(retargeted.absoluteString)")
        completionHandler(rewritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let wasStopped = stopped; lock.unlock()
        if wasStopped { return }
        log("[relay] upstream ended\(error.map { ": \($0.localizedDescription)" } ?? "")")
        onUpstreamEnded?(error)
    }
}
