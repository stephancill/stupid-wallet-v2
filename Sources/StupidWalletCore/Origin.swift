import Foundation

/// Origin normalization shared by connection grants and pending requests.
/// Binds scheme, host, and effective port; never collapses HTTPS/HTTP or ports.
public enum Origin {
  /// Normalizes a raw web origin (e.g. `https://EXAMPLE.com:443`) into a stable key.
  public static func normalize(_ raw: String?) -> String {
    guard let raw, let url = URL(string: raw) else { return raw ?? "unknown" }
    let scheme = url.scheme?.lowercased() ?? "unknown"
    let host = url.host?.lowercased() ?? "unknown"
    let defaultPort = (scheme == "https") ? 443 : (scheme == "http" ? 80 : nil)
    var effectivePort = url.port ?? defaultPort
    if effectivePort == defaultPort { effectivePort = nil }
    if let port = effectivePort {
      return "\(scheme)://\(host):\(port)"
    }
    return "\(scheme)://\(host)"
  }

  /// Display host only, for the review surface.
  public static func displayHost(_ raw: String?) -> String {
    guard let raw, let url = URL(string: raw) else { return raw ?? "unknown" }
    return url.host?.lowercased() ?? raw
  }
}
