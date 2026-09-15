import Foundation

/// Minimal client for the Ace Stream engine HTTP API (reached via the local proxy).
struct AceStreamAPI {
    var baseURL = URL(string: "http://127.0.0.1:6878")!
    /// A stable per-client pid keeps the engine from treating every reconnect as a new
    /// client. Injectable so that several clients of one engine can stay distinct.
    var pid: String = "kakaplayer"
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 90
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    struct EngineVersion: Decodable { let version: String; let code: Int?; let platform: String? }
    struct PlaybackInfo: Decodable {
        // var, not let: the engine fills these in with its own loopback address, which
        // `startStream` rewrites to the host we reached the engine on.
        var playback_url: String
        var stat_url: String
        var command_url: String
        let infohash: String?
        let playback_session_id: String?
        let is_live: Int?
        let is_encrypted: Int?
    }
    struct Stats: Decodable {
        let status: String?
        let peers: Int?
        let speed_down: Int?
        let speed_up: Int?
        let downloaded: Int64?
        let uploaded: Int64?
        let total_progress: Int?
    }
    private struct Envelope<T: Decodable>: Decodable { let response: T?; let result: T?; let error: String? }

    enum APIError: LocalizedError {
        case engine(String)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .engine(let s): return "Engine error: \(s)"
            case .badResponse: return "Unexpected response from the engine."
            }
        }
    }

    private func get<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw APIError.badResponse }
        let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let err = env.error, !err.isEmpty { throw APIError.engine(err) }
        guard let v = env.response ?? env.result else { throw APIError.badResponse }
        return v
    }

    func version() async throws -> EngineVersion {
        try await get(baseURL.appendingPathComponent("webui/api/service").appending(queryItems: [.init(name: "method", value: "get_version")]), as: EngineVersion.self)
    }

    /// Starts a playback session. `hls` selects the HLS manifest endpoint, otherwise MPEG-TS.
    func startStream(_ link: AceLink, hls: Bool = false) async throws -> PlaybackInfo {
        var items = [URLQueryItem(name: "format", value: "json")]
        switch link.kind {
        case .contentID: items.append(.init(name: "id", value: link.value))
        case .infohash: items.append(.init(name: "infohash", value: link.value))
        case .url: items.append(.init(name: "url", value: link.value))
        }
        items.append(.init(name: "pid", value: pid))
        let path = hls ? "ace/manifest.m3u8" : "ace/getstream"
        var info = try await get(baseURL.appendingPathComponent(path).appending(queryItems: items), as: PlaybackInfo.self)
        info.playback_url = Self.rewritingLoopback(info.playback_url, to: baseURL)
        info.stat_url = Self.rewritingLoopback(info.stat_url, to: baseURL)
        info.command_url = Self.rewritingLoopback(info.command_url, to: baseURL)
        return info
    }

    /// The engine reports its URLs as `http://127.0.0.1:6878/...` (or `localhost`, `::1`)
    /// regardless of the address we reached it on. Point them back at `base`'s host and
    /// port, keeping scheme, path and query. Loopback `base`es come out unchanged in
    /// effect, and anything unparseable is returned untouched.
    static func rewritingLoopback(_ url: String, to base: URL) -> String {
        guard let parsed = URL(string: url),
              let retargeted = LoopbackRewrite.retargeted(parsed, to: base)
        else { return url }
        return retargeted.absoluteString
    }

    func stats(_ info: PlaybackInfo) async throws -> Stats {
        guard let url = URL(string: info.stat_url) else { throw APIError.badResponse }
        return try await get(url, as: Stats.self)
    }

    func stop(_ info: PlaybackInfo) async {
        guard let url = URL(string: info.command_url)?.appending(queryItems: [.init(name: "method", value: "stop")]) else { return }
        _ = try? await session.data(from: url)
    }

    /// Finishes this client's URLSession once its in-flight requests are done.
    ///
    /// A URLSession retains itself until it is invalidated, so a client that is dropped
    /// without this call leaks its session and the keep-alive connections it holds to the
    /// engine. Call it whenever a client is discarded — a re-pointed engine address, or a
    /// throwaway client built just to probe an address. Copies of the struct share one
    /// session, so the invalidated client (and every copy of it) is done for good.
    func invalidate() {
        session.finishTasksAndInvalidate()
    }
}

/// A parsed acestream link: `acestream://<40 hex>`, a bare content id / infohash,
/// or an http(s) URL to a transport file.
struct AceLink: Equatable {
    enum Kind { case contentID, infohash, url }
    let kind: Kind
    let value: String

    /// A tidy, canonical string for the input field.
    var canonical: String {
        switch kind {
        case .contentID: return "acestream://\(value)"
        case .infohash: return "infohash:\(value)"
        case .url: return value
        }
    }

    var displayName: String {
        switch kind {
        case .contentID, .infohash: return String(value.prefix(12)) + "…"
        case .url: return value
        }
    }

    static func parse(_ raw: String) -> AceLink? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if let range = s.range(of: "acestream://", options: [.caseInsensitive, .anchored]) {
            s = String(s[range.upperBound...])
            if let q = s.firstIndex(where: { $0 == "?" || $0 == "/" || $0 == "&" }) { s = String(s[..<q]) }
            guard s.count == 40, s.unicodeScalars.allSatisfy(hex.contains) else { return nil }
            return AceLink(kind: .contentID, value: s.lowercased())
        }
        if s.count == 40, s.unicodeScalars.allSatisfy(hex.contains) {
            return AceLink(kind: .contentID, value: s.lowercased())
        }
        if let range = s.range(of: "infohash:", options: [.caseInsensitive, .anchored]) {
            let h = String(s[range.upperBound...])
            guard h.count == 40, h.unicodeScalars.allSatisfy(hex.contains) else { return nil }
            return AceLink(kind: .infohash, value: h.lowercased())
        }
        if let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            // Direct links to the engine's own /ace/getstream?id=... are common in playlists.
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               comps.path.hasPrefix("/ace/"),
               let id = comps.queryItems?.first(where: { $0.name == "id" || $0.name == "content_id" })?.value {
                return parse(id)
            }
            return AceLink(kind: .url, value: s)
        }
        return nil
    }
}
