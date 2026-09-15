import Foundation

/// The Ace Stream engine builds the URLs it hands out (`playback_url`, `stat_url`,
/// `command_url`, and the `Location` of its `/ace/r/...` redirects) from *its own*
/// loopback address. That is fine while the engine and the player share a host, but a
/// client on another device would follow those URLs straight into its own loopback.
/// These helpers retarget such URLs at the host we actually reached the engine on.
enum LoopbackRewrite {
    /// Host spellings that mean "this machine". Any address in 127.0.0.0/8 counts too —
    /// the engine has been seen using 127.0.0.2 when its own listener is bound there.
    static let loopbackHosts: Set<String> = ["localhost", "::1"]

    static func isLoopback(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let h = host.lowercased()
        if loopbackHosts.contains(h) { return true }
        // 127.0.0.0/8, without matching a hostname that merely starts with "127."
        return h.hasPrefix("127.") && h.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// `url` with its host and port replaced by `base`'s, keeping scheme, path, query and
    /// fragment. Returns `nil` when `url`'s host is not loopback, when `base` has no host,
    /// or when the result cannot be rebuilt — callers then keep the original URL.
    ///
    /// Both hosts travel as `encodedHost`: `URL.host` strips the brackets from an IPv6
    /// literal, and feeding that back through `URLComponents.host` makes `comps.url` nil,
    /// which would silently leave an IPv6 base pointing at the client's own loopback.
    static func retargeted(_ url: URL, to base: URL) -> URL? {
        guard isLoopback(url.host),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let baseComps = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let baseHost = baseComps.encodedHost, !baseHost.isEmpty else { return nil }
        comps.encodedHost = baseHost
        comps.port = baseComps.port
        return comps.url
    }
}
