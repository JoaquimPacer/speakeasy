import SwiftUI
import UIKit

struct SettingsStorageView: View {
    @EnvironmentObject private var appState: AppState
    var onInviteAccepted: () -> Void = {}

    @State private var relayURLDraft = ""
    @State private var inviteCodeDraft = ""
    @State private var copiedInviteCode = false
    @State private var showingDeleteAccountConfirmation = false
    @State private var showingResetRegistrationConfirmation = false
    @FocusState private var focusedField: FocusedField?

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

            Section("Contacts") {
                Button {
                    Task {
                        await appState.createContactInvite()
                    }
                } label: {
                    Label("Create invite", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(appState.isWorking)

                if let inviteCode = appState.lastInviteCode {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Invite code")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Text(inviteCode)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Spacer(minLength: 8)

                            Button {
                                UIPasteboard.general.string = inviteCode
                                copiedInviteCode = true
                            } label: {
                                Label(copiedInviteCode ? "Copied" : "Copy", systemImage: copiedInviteCode ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            ShareLink(item: inviteCode) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Share invite code")
                        }
                    }
                }

                TextField("SPEAK-ABCD-1234-EF56", text: $inviteCodeDraft)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .inviteCode)
                    .submitLabel(.done)
                    .onSubmit {
                        acceptInvite()
                    }
                    .onChange(of: inviteCodeDraft) { newValue in
                        let formattedCode = InviteCodeFormatter.format(newValue)
                        if formattedCode != newValue {
                            inviteCodeDraft = formattedCode
                        }
                    }

                Button {
                    acceptInvite()
                } label: {
                    Label("Accept invite", systemImage: "checkmark.seal")
                }
                .disabled(appState.isWorking || !InviteCodeFormatter.isComplete(inviteCodeDraft))
            }

            Section("Account") {
                if let user = appState.currentUser {
                    LabeledContent("Username", value: user.username)
                    LabeledContent("User ID", value: user.id.uuidString)
                }

                Button {
                    Task {
                        await appState.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isWorking)

                Button(role: .destructive) {
                    showingDeleteAccountConfirmation = true
                } label: {
                    Label("Delete account", systemImage: "person.crop.circle.badge.xmark")
                }
                .disabled(appState.isWorking || appState.currentUser == nil)

                Button(role: .destructive) {
                    showingResetRegistrationConfirmation = true
                } label: {
                    Label("Reset local registration", systemImage: "arrow.counterclockwise.circle")
                }
                .disabled(appState.isWorking)
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

            if let error = appState.lastErrorMessage {
                Section("Status") {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Color.clear
                    .frame(height: 96)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            relayURLDraft = appState.relayBaseURLString
        }
        .onChange(of: appState.lastInviteCode) { _ in
            copiedInviteCode = false
        }
        .confirmationDialog(
            "Delete your Kithra account?",
            isPresented: $showingDeleteAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task {
                    await appState.deleteAccount()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your relay account and clears local encrypted media, invite state, and device keys from this device.")
        }
        .confirmationDialog(
            "Reset this device's local registration?",
            isPresented: $showingResetRegistrationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset local registration", role: .destructive) {
                Task {
                    await appState.resetLocalRegistration()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use this when switching to a new relay. It keeps the relay URL, then clears the saved account token, local encrypted media, invite state, and device keys on this device.")
        }
    }

    private func acceptInvite() {
        focusedField = nil
        Task {
            let accepted = await appState.acceptContactInvite(code: inviteCodeDraft)
            guard accepted else {
                return
            }

            inviteCodeDraft = ""
            onInviteAccepted()
        }
    }
}

private enum FocusedField: Hashable {
    case inviteCode
}

private enum InviteCodeFormatter {
    private static let prefix = "SPEAK"
    private static let suffixLength = 12

    static func format(_ text: String) -> String {
        let cleaned = text
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }

        guard !cleaned.isEmpty else {
            return ""
        }

        if prefix.hasPrefix(cleaned) {
            return cleaned == prefix ? "\(prefix)-" : cleaned
        }

        var suffixSource = cleaned
        if suffixSource.hasPrefix(prefix) {
            suffixSource.removeFirst(prefix.count)
        }

        let suffix = suffixSource
            .filter(\.isInviteCodeSuffixCharacter)
            .prefix(suffixLength)
        var parts = [prefix]
        var currentIndex = suffix.startIndex
        while currentIndex < suffix.endIndex {
            let nextIndex = suffix.index(currentIndex, offsetBy: 4, limitedBy: suffix.endIndex) ?? suffix.endIndex
            parts.append(String(suffix[currentIndex..<nextIndex]))
            currentIndex = nextIndex
        }

        return parts.joined(separator: "-")
    }

    static func isComplete(_ text: String) -> Bool {
        let formattedCode = format(text)
        guard formattedCode.hasPrefix("\(prefix)-") else {
            return false
        }

        let suffixCount = formattedCode
            .dropFirst(prefix.count)
            .filter(\.isInviteCodeSuffixCharacter)
            .count
        return suffixCount == suffixLength
    }
}

private extension Character {
    var isInviteCodeSuffixCharacter: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else {
            return false
        }

        return (48...57).contains(scalar.value) || (65...70).contains(scalar.value)
    }
}

struct SettingsStorageView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SettingsStorageView()
        }
        .environmentObject(AppState())
    }
}
