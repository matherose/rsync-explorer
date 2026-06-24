import Foundation

struct SavedConnection: Codable, Equatable {
    var host: String
    var port: Int
    var username: String
    var remotePath: String
}

/// Persists the connection: non-secret fields in UserDefaults, password in the Keychain.
enum ConnectionStore {
    private static let defaultsKey = "savedConnection"
    private static let pwAccount = "connectionPassword"
    private static let store = CredentialStore()

    static func save(_ connection: SavedConnection, password: String) {
        if let data = try? JSONEncoder().encode(connection) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        try? store.save(Data(password.utf8), account: pwAccount)
    }

    static func load() -> (connection: SavedConnection, password: String)? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let connection = try? JSONDecoder().decode(SavedConnection.self, from: data),
              let pwData = store.load(account: pwAccount),
              let password = String(data: pwData, encoding: .utf8)
        else { return nil }
        return (connection, password)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        store.delete(account: pwAccount)
        HostKeyStore().clearAll()   // re-trust the host key on the next connection
    }
}
