import SwiftUI

struct RootView: View {
    @State private var session: BrowserSession?
    @State private var booting = true
    @State private var bootError: String?

    var body: some View {
        if let session {
            BrowserView(session: session) { self.session = nil }
        } else if booting {
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting…").foregroundStyle(.secondary)
            }
            .task { await tryAutoConnect() }
        } else {
            ConnectionView(initial: ConnectionStore.load(), initialError: bootError) {
                self.session = $0
            }
        }
    }

    private func tryAutoConnect() async {
        defer { booting = false }
        guard let saved = ConnectionStore.load() else { return }
        do {
            session = try await Connector.connect(saved.connection, password: saved.password)
        } catch {
            bootError = "Saved connection failed — check the details below."
        }
    }
}
