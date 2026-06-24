import Foundation

/// Remembers the SSH host-key fingerprint trusted for each host:port. A public-key
/// fingerprint is not secret, so UserDefaults is fine (no Keychain needed).
struct HostKeyStore {
    private static let prefix = "hostkey:"

    private func key(host: String, port: Int) -> String { "\(Self.prefix)\(host):\(port)" }

    func fingerprint(host: String, port: Int) -> String? {
        UserDefaults.standard.string(forKey: key(host: host, port: port))
    }

    func save(fingerprint: String, host: String, port: Int) {
        UserDefaults.standard.set(fingerprint, forKey: key(host: host, port: port))
    }

    /// Removes every pinned host key (used by "Forget saved connection").
    func clearAll() {
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix(Self.prefix) {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
}
