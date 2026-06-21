import Foundation

enum AuthMethod: String, Codable { case ed25519Key, password }

struct ServerConfig: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var remotePath: String
    var authMethod: AuthMethod
    /// Set only transiently during import; secrets are moved to Keychain by the caller.
    var importedKeyPath: String? = nil
}
