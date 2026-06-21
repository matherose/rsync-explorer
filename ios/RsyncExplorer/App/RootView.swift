import SwiftUI

struct RootView: View {
    @State private var session: BrowserSession?

    var body: some View {
        if let session {
            BrowserView(session: session) { self.session = nil }
        } else {
            ConnectionView { self.session = $0 }
        }
    }
}
