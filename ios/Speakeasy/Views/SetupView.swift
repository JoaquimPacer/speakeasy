import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var appState: AppState
    @State private var relayURLDraft = ""
    @State private var username = ""
    @State private var showingResetRegistrationConfirmation = false

    var body: some View {
        Form {
            Section("Relay") {
                TextField("Relay URL", text: $relayURLDraft)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .disabled(appState.isAuthenticationBootstrapUncertain)

                Button {
                    Task {
                        await appState.updateRelayBaseURL(relayURLDraft)
                    }
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .disabled(appState.isSetupMutationBlocked)
            }

            Section("Device") {
                if appState.needsLocalCleanupRetry {
                    Text("A previously confirmed local reset did not finish. Retry that cleanup before creating or registering a device identity.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry confirmed local cleanup", role: .destructive) {
                        Task {
                            await appState.resetLocalRegistration(
                                confirmation: .eraseProtectedLocalAccount
                            )
                        }
                    }
                    .disabled(appState.isWorking)
                } else if appState.needsAuthenticationStorageReload {
                    Text("Kithra could not safely reconcile the protected session and pending-registration records. Reloading is non-destructive and never replaces or erases device keys.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Reload protected account storage") {
                        Task {
                            await appState.retryAuthenticationStorageLoad()
                        }
                    }
                    .disabled(appState.isWorking || appState.isRestoringSession)
                    Button("Reset this device instead", role: .destructive) {
                        showingResetRegistrationConfirmation = true
                    }
                    .disabled(appState.isWorking || appState.isRestoringSession)
                } else if appState.needsAuthenticationRecoveryRetry {
                    Text("Kithra has protected account authority for this exact relay and device, but recovery did not finish. Retry without creating a replacement account or keys.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry protected account recovery") {
                        Task {
                            await appState.retryAuthenticationRecovery()
                        }
                    }
                    .disabled(appState.isWorking || appState.isRestoringSession)
                    Button("Reset this device instead", role: .destructive) {
                        showingResetRegistrationConfirmation = true
                    }
                    .disabled(appState.isWorking || appState.isRestoringSession)
                } else if let identity = appState.deviceIdentity {
                    LabeledContent("Device", value: identity.deviceID?.uuidString ?? "Ready")
                    LabeledContent("Encryption key", value: "\(identity.encryptionPublicKey.count) bytes")
                    LabeledContent("Signing key", value: "\(identity.signingPublicKey.count) bytes")
                    if identity.deviceID != nil {
                        Text("This identity is already bound to a relay account. Reset it before creating a replacement registration.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Reset local identity", role: .destructive) {
                            showingResetRegistrationConfirmation = true
                        }
                        .disabled(appState.isWorking)
                    }
                } else {
                    Button {
                        Task {
                            await appState.prepareLocalIdentity()
                        }
                    } label: {
                        Label("Create local keys", systemImage: "key")
                    }
                    .disabled(appState.isSetupMutationBlocked)
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
                .disabled(
                    appState.isSetupMutationBlocked
                        || appState.deviceIdentity?.deviceID != nil
                )
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
        .confirmationDialog(
            "Reset this device's local registration?",
            isPresented: $showingResetRegistrationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset local registration", role: .destructive) {
                Task {
                    await appState.resetLocalRegistration(
                        confirmation: .eraseProtectedLocalAccount
                    )
                    if !appState.isAuthenticationBootstrapUncertain {
                        await appState.prepareLocalIdentity()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently erases this device's protected session, pending registration, verification state, encrypted local media, and device keys. It does not recover an unknown relay response.")
        }
        .task {
            if appState.deviceIdentity == nil,
               !appState.isAuthenticationBootstrapUncertain {
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
