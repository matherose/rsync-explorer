import SwiftUI

struct BrowserSession {
    let service: SFTPService
    let context: SnapshotResolver.Context
}

struct BrowserView: View {
    let session: BrowserSession
    var onDisconnect: () -> Void

    var body: some View {
        NavigationStack {
            DirectoryView(route: rootRoute, service: session.service)
                .navigationDestination(for: DirRoute.self) { route in
                    DirectoryView(route: route, service: session.service)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect") {
                            Task {
                                await session.service.disconnect()
                                onDisconnect()
                            }
                        }
                    }
                }
        }
    }

    private var rootRoute: DirRoute {
        DirRoute(path: session.context.latestRoot,
                 latestRoot: session.context.latestRoot,
                 previousRoot: session.context.previousRoot,
                 title: "Backup")
    }
}
