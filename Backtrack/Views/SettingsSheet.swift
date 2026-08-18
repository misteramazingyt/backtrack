import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.y.z:8790", text: $state.serverURLString)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Token (optional)", text: $state.serverToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Desktop server")
                } footer: {
                    Text("Run desktop-server/server.py on your computer and connect over Tailscale. The traffic is WireGuard-encrypted end to end.")
                }

                Section {
                    Button("Test connection") {
                        testConnection()
                    }
                    if let testResult {
                        Text(testResult)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func testConnection() {
        testResult = "Testing..."
        guard let client = state.client else {
            testResult = "Enter a valid URL first."
            return
        }
        Task {
            do {
                let h = try await client.health()
                var parts = ["Connected", "device: \(h.device ?? "?")"]
                parts.append(h.spotify_configured == true
                             ? "Spotify now-playing: on" : "Spotify now-playing: off")
                testResult = parts.joined(separator: " | ")
                state.startNowPlayingRefresh()
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
        }
    }
}
