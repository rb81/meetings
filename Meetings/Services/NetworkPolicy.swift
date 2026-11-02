import Foundation

/// The one place that decides whether the app may reach a server.
///
/// In offline mode only this Mac is reachable: loopback addresses such as a local Ollama server.
/// Apple Intelligence never uses the network. Downloading the speech model is the only other exception,
/// and it's handled by the model manager, which only runs when you press Download or Repair.
enum NetworkPolicy {
    static let offlineKey = "offlineMode"

    static var isOffline: Bool {
        UserDefaults.standard.bool(forKey: offlineKey)
    }

    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    static func allows(_ url: URL) -> Bool {
        !isOffline || isLocal(url)
    }
}
