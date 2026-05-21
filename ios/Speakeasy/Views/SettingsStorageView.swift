import SwiftUI

struct SettingsStorageView: View {
    @EnvironmentObject private var appState: AppState
    @State private var relayURLDraft = ""

    var body: some View {
        Form {
            Section("Relay") {
                TextField("Relay URL", text: $relayURLDraft)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                Button {
                    appState.updateRelayBaseURL(relayURLDraft)
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
            }

            Section("Device") {
                if let identity = appState.deviceIdentity {
                    LabeledContent("Device ID", value: identity.deviceID?.uuidString ?? "Pending registration")
                    LabeledContent("Encryption key", value: "\(identity.encryptionPublicKey.count) bytes")
                    LabeledContent("Signing key", value: "\(identity.signingPublicKey.count) bytes")
                } else {
                    Label("No local device key", systemImage: "key.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Storage") {
                Label("Encrypted local history", systemImage: "lock.doc")
                Label("Plaintext playback temp files", systemImage: "timer")

                Button(role: .destructive) {
                } label: {
                    Label("Clean temporary files", systemImage: "trash")
                }
                .disabled(true)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            relayURLDraft = appState.relayBaseURLString
        }
    }
}

#Preview {
    NavigationStack {
        SettingsStorageView()
    }
    .environmentObject(AppState())
}
