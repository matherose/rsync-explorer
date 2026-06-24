import SwiftUI

struct ConnectionView: View {
    let initial: (connection: SavedConnection, password: String)?
    let initialError: String?
    var onConnected: (BrowserSession) -> Void

    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var remotePath: String
    @State private var pointerName: String
    @State private var busy = false
    @State private var error: String

    init(initial: (connection: SavedConnection, password: String)?,
         initialError: String?,
         onConnected: @escaping (BrowserSession) -> Void) {
        self.initial = initial
        self.initialError = initialError
        self.onConnected = onConnected
        _host = State(initialValue: initial?.connection.host ?? "")
        _port = State(initialValue: String(initial?.connection.port ?? 22))
        _username = State(initialValue: initial?.connection.username ?? "")
        _password = State(initialValue: initial?.password ?? "")
        _remotePath = State(initialValue: initial?.connection.remotePath ?? "")
        _pointerName = State(initialValue: initial?.connection.latestPointerName ?? "")
        _error = State(initialValue: initialError ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("NAS") {
                    TextField("Host (e.g. 192.168.1.100)", text: $host)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                }
                Section {
                    TextField("Path to all snapshots, e.g. /mnt/nas/BACK_EXT", text: $remotePath)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Latest-snapshot pointer (default: latest)", text: $pointerName)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: {
                    Text("Snapshots")
                } footer: {
                    Text("The symlink in that folder pointing to the newest snapshot. Leave blank to use “latest”.")
                }
                if !error.isEmpty {
                    Section { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                }
                Button(busy ? "Connecting…" : "Connect") { Task { await connect() } }
                    .disabled(busy || host.isEmpty || username.isEmpty || password.isEmpty || remotePath.isEmpty)
                if initial != nil {
                    Section {
                        Button("Forget saved connection", role: .destructive) {
                            ConnectionStore.clear()
                            host = ""; port = "22"; username = ""; password = ""
                            remotePath = ""; pointerName = ""; error = ""
                        }
                    }
                }
            }
            .navigationTitle("Connect to NAS")
        }
    }

    private func connect() async {
        busy = true; error = ""
        defer { busy = false }
        let trimmedPointer = pointerName.trimmingCharacters(in: .whitespaces)
        let conn = SavedConnection(host: host, port: Int(port) ?? 22,
                                   username: username, remotePath: remotePath,
                                   latestPointerName: trimmedPointer.isEmpty ? nil : trimmedPointer)
        do {
            let session = try await Connector.connect(conn, password: password)
            ConnectionStore.save(conn, password: password)
            onConnected(session)
        } catch {
            self.error = (error as? SFTPConnectError)?.userMessage ?? "Connection failed:\n\(error)"
        }
    }
}
