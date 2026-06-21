import Foundation

enum ConfigImporter {
    /// Builds ServerConfigs from the `remote.*` sections of a config.ini. Local sections are ignored.
    static func servers(from text: String) -> [ServerConfig] {
        INIParser.parse(text).compactMap { (section, kv) -> ServerConfig? in
            guard section.hasPrefix("remote.") else { return nil }
            let name = String(section.dropFirst("remote.".count))
            guard let host = kv["host"], let user = kv["ssh_user"], let dest = kv["dest"]
            else { return nil }
            let hasKey = (kv["ssh_key"]?.isEmpty == false)
            return ServerConfig(
                name: name,
                host: host,
                port: Int(kv["port"] ?? "") ?? 22,
                username: user,
                remotePath: dest,
                authMethod: hasKey ? .ed25519Key : .password,
                importedKeyPath: hasKey ? kv["ssh_key"] : nil
            )
        }
        .sorted { $0.name < $1.name }
    }
}
