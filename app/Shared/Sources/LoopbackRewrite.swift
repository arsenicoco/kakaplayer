import Foundation

/// The Ace Stream engine builds the URLs it hands out (`playback_url`, `stat_url`,
/// `command_url`, and the `Location` of its `/ace/r/...` redirects) from *its own*
/// loopback address. That is fine while the engine and the player share a host, but a
/// client on another device would follow those URLs straight into its own loopback.
/// These helpers retarget such URLs at the host we actually reached the engine on.
enum LoopbackRewrite {
    /// Host spellings that mean "this machine".
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    static func isLoopback(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        return loopbackHosts.contains(host.lowercased())
    }

    /// `url` with its host and port replaced by `base`'s, keeping scheme, path, query and
    /// fragment. Returns `nil` when `url`'s host is not loopback, when `base` has no host,
    /// or when the result cannot be rebuilt — callers then keep the original URL.
    static func retargeted(_ url: URL, to base: URL) -> URL? {
        guard isLoopback(url.host), let baseHost = base.host, !baseHost.isEmpty else { return nil }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.host = baseHost
        comps.port = base.port
        return comps.url
    }
}
