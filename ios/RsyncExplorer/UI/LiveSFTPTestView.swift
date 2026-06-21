import SwiftUI

/// TEMPORARY Phase C harness: type real NAS details, connect over SFTP, and list
/// the latest snapshot to prove CitadelSFTPService against a live server.
/// Replaced by OnboardingView + DirectoryView in Phase F.
struct LiveSFTPTestView: View {
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var remotePath = ""
    @State private var auth: AuthMethod = .ed25519Key
    @State private var secret = ""
    @State private var status = ""
    @State private var entries: [RemoteEntry] = []
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("NAS") {
                    TextField("Host (e.g. 192.168.1.100)", text: $host)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Backup root path (dest)", text: $remotePath)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section("Auth") {
                    Picker("Method", selection: $auth) {
                        Text("ed25519 key").tag(AuthMethod.ed25519Key)
                        Text("Password").tag(AuthMethod.password)
                    }
                    if auth == .ed25519Key {
                        TextField("Paste unencrypted id_ed25519 PEM", text: $secret, axis: .vertical)
                            .lineLimit(3...6).font(.caption.monospaced())
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    } else {
                        SecureField("Password", text: $secret)
                    }
                }
                Button(busy ? "Connecting…" : "Connect & list latest snapshot") {
                    Task { await run() }
                }
                .disabled(busy || host.isEmpty || username.isEmpty || remotePath.isEmpty || secret.isEmpty)

                if !status.isEmpty {
                    Section("Result") { Text(status).font(.callout).textSelection(.enabled) }
                }
                if !entries.isEmpty {
                    Section("Entries (\(entries.count))") {
                        ForEach(entries.prefix(50)) { e in
                            HStack {
                                Image(systemName: e.isDirectory ? "folder" : "doc")
                                Text(e.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Live SFTP test")
        }
    }

    private func run() async {
        busy = true; status = ""; entries = []
        defer { busy = false }
        let config = ServerConfig(name: "live", host: host, port: Int(port) ?? 22,
                                  username: username, remotePath: remotePath, authMethod: auth)
        do {
            let a = try CitadelSFTPService.makeAuth(for: config, secret: secret)
            let svc = CitadelSFTPService(config: config, auth: a)
            try await svc.connect()
            let snap = try await svc.resolveLatestSnapshot(under: remotePath)
            let list = try await svc.listDirectory(snap)
            await svc.disconnect()
            status = "OK — latest snapshot:\n\(snap)\n\(list.count) entries"
            entries = list
        } catch {
            status = "FAILED:\n\(error)"
        }
    }
}
