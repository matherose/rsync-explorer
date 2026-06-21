import SwiftUI

private struct PlayerItem: Identifiable { let id = UUID(); let url: URL }

/// TEMPORARY Phase C/D harness: type real NAS details, connect over SFTP, list
/// the latest snapshot, and download+play a video through VLCKit to prove the
/// stack against a live server. Replaced by OnboardingView + DirectoryView in Phase F.
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

    // Phase D additions
    @State private var service: CitadelSFTPService?
    @State private var videoPath = ""
    @State private var downloadStatus = ""
    @State private var playerItem: PlayerItem?

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
                if service != nil {
                    Section("Play a video (Phase D)") {
                        TextField("Full path to a video on the NAS", text: $videoPath, axis: .vertical)
                            .lineLimit(2...4).font(.caption.monospaced())
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Download & play") { Task { await playVideo() } }
                            .disabled(videoPath.isEmpty || busy)
                        if !downloadStatus.isEmpty {
                            Text(downloadStatus).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Live SFTP test")
            .fullScreenCover(item: $playerItem) { item in
                VLCPlayerView(url: item.url) { playerItem = nil }
            }
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
            service = svc
            if videoPath.isEmpty { videoPath = snap + "/" }
            status = "OK — latest snapshot:\n\(snap)\n\(list.count) entries"
            entries = list
        } catch {
            status = "FAILED:\n\(error)"
        }
    }

    private func playVideo() async {
        guard let svc = service else { return }
        busy = true; downloadStatus = "Downloading…"
        defer { busy = false }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + (videoPath as NSString).lastPathComponent)
        do {
            try await svc.download(videoPath, to: tmp) { p in
                Task { @MainActor in downloadStatus = "Downloading… \(Int(p * 100))%" }
            }
            downloadStatus = "Downloaded — opening player"
            playerItem = PlayerItem(url: tmp)
        } catch {
            downloadStatus = "Download FAILED:\n\(error)"
        }
    }
}
