import SwiftUI

struct SettingsView: View {
    var onDisconnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Cache") {
                    LabeledContent("On disk", value: ByteCountFormatter.string(
                        fromByteCount: cacheSize, countStyle: .file))
                    Button(role: .destructive) {
                        CacheManager.clear()
                        cacheSize = CacheManager.totalSize()
                    } label: {
                        Text("Clear cache")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        dismiss()
                        onDisconnect()
                    } label: {
                        Text("Disconnect")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { cacheSize = CacheManager.totalSize() }
        }
    }
}
