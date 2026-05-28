import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var relayURLDraft = ""
    @State private var username = ""

    var body: some View {
        Form {
            Section("Relay") {
                TextField("Relay URL", text: $relayURLDraft)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                Button {
                    Task {
                        await appState.updateRelayBaseURL(relayURLDraft)
                    }
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .disabled(appState.isWorking)
            }

            Section("Device") {
                if let identity = appState.deviceIdentity {
                    LabeledContent("Device", value: identity.deviceID?.uuidString ?? "Ready")
                    LabeledContent("Encryption key", value: "\(identity.encryptionPublicKey.count) bytes")
                    LabeledContent("Signing key", value: "\(identity.signingPublicKey.count) bytes")
                } else {
                    Button {
                        Task {
                            await appState.prepareLocalIdentity()
                        }
                    } label: {
                        Label("Create local keys", systemImage: "key")
                    }
                }
            }

            Section("Account") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    Task {
                        await appState.register(username: username)
                    }
                } label: {
                    Label("Register", systemImage: "person.badge.plus")
                }
                .disabled(appState.isWorking)
            }

            if let error = appState.lastErrorMessage {
                Section("Status") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Kithra")
        .overlay {
            if appState.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear {
            relayURLDraft = appState.relayBaseURLString
        }
        .task {
            if appState.deviceIdentity == nil {
                await appState.prepareLocalIdentity()
            }
        }
    }
}

struct SetupView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SetupView()
        }
        .environmentObject(AppState(seedPreviewData: false))
    }
}
