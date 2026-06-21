import SwiftUI

struct ConnectionView: View {
    var onConnected: (BrowserSession) -> Void

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var remotePath = ""
    @State private var auth: AuthMethod = .ed25519Key
    @State private var secret = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("NAS") {
                    TextField("Host (e.g. 192.168.1.100)", text: $host)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Backup root path (contains 'latest')", text: $remotePath)
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
                if !error.isEmpty {
                    Section { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                }
                Button(busy ? "Connecting…" : "Connect") { Task { await connect() } }
                    .disabled(busy || host.isEmpty || username.isEmpty || remotePath.isEmpty || secret.isEmpty)
            }
            .navigationTitle("Connect to NAS")
        }
    }

    private func connect() async {
        busy = true; error = ""
        defer { busy = false }
        let config = ServerConfig(name: "nas", host: host, port: Int(port) ?? 22,
                                  username: username, remotePath: remotePath, authMethod: auth)
        do {
            let a = try CitadelSFTPService.makeAuth(for: config, secret: secret)
            let svc = CitadelSFTPService(config: config, auth: a)
            try await svc.connect()
            let entries = try await svc.listDirectory(remotePath)
            let roots = SnapshotResolver.snapshotRoots(remotePath: remotePath, entries: entries)
            onConnected(BrowserSession(service: svc, snapshotRoots: roots))
        } catch {
            self.error = "Connection failed:\n\(error)"
        }
    }
}
