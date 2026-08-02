import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ContactSecurityView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var signedQRCode: String?
    @State private var isPreparingQRCode = false
    @State private var isVerifying = false
    @State private var showingScanner = false
    @State private var showingManualConfirmation = false
    @State private var manualComparisonContact: Contact?
    @State private var manualComparisonDigest: Data?
    @State private var resultMessage: ContactVerificationResultMessage?

    let contact: Contact

    private var currentContact: Contact {
        appState.contacts.first { $0.contactID == contact.contactID } ?? contact
    }

    private var trustState: ContactTrustState {
        appState.trustState(for: currentContact)
    }

    private var safetyNumber: ContactSafetyNumber? {
        appState.safetyNumber(for: currentContact)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                verificationStatusCard
                comparisonInstructions
                safetyNumberCard
                signedQRCodeCard

                if let errorMessage = appState.lastErrorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Verification error: \(errorMessage)")
                }
            }
            .padding()
        }
        .navigationTitle("Contact Security")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .overlay {
            if isVerifying {
                ProgressView("Verifying")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: currentContact) {
            await prepareSignedQRCode(for: currentContact)
        }
        .fullScreenCover(isPresented: $showingScanner) {
            NavigationStack {
                ContactQRCodeScannerScreen(
                    contactName: currentContact.displayName,
                    onScan: { scannedCode in
                        showingScanner = false
                        verify(scannedCode: scannedCode)
                    },
                    onCancel: {
                        showingScanner = false
                    }
                )
            }
        }
        .confirmationDialog(
            manualConfirmationTitle,
            isPresented: $showingManualConfirmation,
            titleVisibility: .visible
        ) {
            Button(manualConfirmationButtonTitle) {
                confirmManualComparison()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only continue after both of you compared every digit and the complete 60-digit number matched on both devices.")
        }
        .alert(item: $resultMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var verificationStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: trustState.largeSystemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(trustState.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(trustState.securityTitle)
                        .font(.title3.weight(.semibold))
                    Text(currentContact.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Text(trustState.securityExplanation(contactName: currentContact.displayName))
                .font(.subheadline)
                .foregroundStyle(trustState == .keyChanged ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(trustState.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(trustState.tint.opacity(0.35), lineWidth: trustState == .keyChanged ? 2 : 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var comparisonInstructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Verify together", systemImage: "person.2.fill")
                .font(.headline)

            Text("Both you and \(currentContact.displayName) must compare the complete safety number or scan each other’s QR code. Do this side-by-side or over a trusted call before exchanging videos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var safetyNumberCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Safety number", systemImage: "number")
                .font(.headline)

            if let safetyNumber {
                Text(safetyNumber.formattedDigits)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .lineSpacing(7)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Safety number, \(safetyNumber.digits.map(String.init).joined(separator: " "))")
            } else {
                Label("The safety number is unavailable. Refresh the contact and try again.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Read and compare all 12 groups. Matching only part of the number is not enough.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                manualComparisonContact = currentContact
                manualComparisonDigest = safetyNumber?.digest
                showingManualConfirmation = true
            } label: {
                Label(manualComparisonLabel, systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(safetyNumber == nil || isVerifying || appState.isWorking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var signedQRCodeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Scan both ways", systemImage: "qrcode")
                .font(.headline)

            Text("Have \(currentContact.displayName) scan this signed code, then scan the signed code shown on their device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if let signedQRCode,
                   let image = ContactVerificationQRCodeRenderer.image(for: signedQRCode) {
                    Image(
                        image,
                        scale: 1,
                        orientation: .up,
                        label: Text("Signed verification QR code for \(currentContact.displayName)")
                    )
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                } else if isPreparingQRCode {
                    ProgressView("Preparing signed code")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    Label("The signed QR code could not be prepared.", systemImage: "qrcode")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)

            Button {
                showingScanner = true
            } label: {
                Label("Scan \(currentContact.displayName)’s code", systemImage: "viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying || appState.isWorking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var manualComparisonLabel: String {
        trustState == .keyChanged ? "Re-verify all 60 digits" : "We compared all 60 digits"
    }

    private var manualConfirmationTitle: String {
        trustState == .keyChanged ? "Trust the new safety number?" : "Did every digit match?"
    }

    private var manualConfirmationButtonTitle: String {
        trustState == .keyChanged ? "Trust New Safety Number" : "Mark as Verified"
    }

    @MainActor
    private func prepareSignedQRCode(for contactSnapshot: Contact) async {
        isPreparingQRCode = true
        signedQRCode = nil
        let preparedCode = await appState.contactVerificationQRCode(for: contactSnapshot)
        guard !Task.isCancelled, currentContact == contactSnapshot else {
            return
        }
        signedQRCode = preparedCode
        isPreparingQRCode = false
    }

    private func verify(scannedCode: String) {
        let contactSnapshot = currentContact
        isVerifying = true
        Task {
            let verified = await appState.verifyContact(contactSnapshot, scannedQRCode: scannedCode)
            guard currentContact == contactSnapshot else {
                await appState.refreshQuietly()
                isVerifying = false
                resultMessage = identityChangedResult
                return
            }
            isVerifying = false
            resultMessage = verified
                ? ContactVerificationResultMessage(
                    title: "Contact verified",
                    message: "The signed QR code and complete safety number matched \(currentContact.displayName)’s current device identity."
                )
                : ContactVerificationResultMessage(
                    title: "Could not verify",
                    message: appState.lastErrorMessage ?? "The scanned code did not match this contact’s current identity."
                )
        }
    }

    private func confirmManualComparison() {
        guard let contactSnapshot = manualComparisonContact,
              let digestSnapshot = manualComparisonDigest,
              contactSnapshot == currentContact,
              safetyNumber?.constantTimeMatches(digest: digestSnapshot) == true else {
            manualComparisonContact = nil
            manualComparisonDigest = nil
            resultMessage = ContactVerificationResultMessage(
                title: "Safety number changed",
                message: "The contact identity changed while you were comparing. Compare the new complete safety number before verifying."
            )
            return
        }

        manualComparisonContact = nil
        manualComparisonDigest = nil
        isVerifying = true
        Task {
            let verified = await appState.confirmSafetyNumberComparison(
                for: contactSnapshot,
                expectedSafetyDigest: digestSnapshot
            )
            guard currentContact == contactSnapshot else {
                await appState.refreshQuietly()
                isVerifying = false
                resultMessage = identityChangedResult
                return
            }
            isVerifying = false
            resultMessage = verified
                ? ContactVerificationResultMessage(
                    title: "Contact verified",
                    message: "Kithra saved the identity represented by the complete safety number you compared."
                )
                : ContactVerificationResultMessage(
                    title: "Could not verify",
                    message: appState.lastErrorMessage ?? "The safety-number verification could not be saved."
                )
        }
    }

    private var identityChangedResult: ContactVerificationResultMessage {
        ContactVerificationResultMessage(
            title: "Safety number changed",
            message: "The contact identity changed during verification. Compare the new complete safety number before continuing."
        )
    }
}

struct ContactTrustBadge: View {
    let state: ContactTrustState
    var compact = false

    var body: some View {
        Label(compact ? state.compactBadgeTitle : state.badgeTitle, systemImage: state.badgeSystemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(state.tint.opacity(0.16), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(state.tint.opacity(0.28), lineWidth: 1)
            }
            .accessibilityLabel("Contact verification status: \(state.accessibilityTitle)")
    }
}

private struct ContactVerificationResultMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum ContactVerificationQRCodeRenderer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            return nil
        }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return context.createCGImage(scaledImage, from: scaledImage.extent)
    }
}

extension ContactTrustState {
    fileprivate var compactBadgeTitle: String {
        switch self {
        case .unverified:
            return "Verify"
        case .verified:
            return "Verified"
        case .keyChanged:
            return "Changed"
        }
    }

    fileprivate var badgeTitle: String {
        switch self {
        case .unverified:
            return "Verify contact"
        case .verified:
            return "Verified"
        case .keyChanged:
            return "Safety number changed"
        }
    }

    fileprivate var accessibilityTitle: String {
        switch self {
        case .unverified:
            return "not verified"
        case .verified:
            return "verified"
        case .keyChanged:
            return "safety number changed"
        }
    }

    fileprivate var badgeSystemImage: String {
        switch self {
        case .unverified:
            return "shield"
        case .verified:
            return "checkmark.shield.fill"
        case .keyChanged:
            return "exclamationmark.shield.fill"
        }
    }

    fileprivate var largeSystemImage: String {
        badgeSystemImage
    }

    fileprivate var tint: Color {
        switch self {
        case .unverified:
            return .orange
        case .verified:
            return .green
        case .keyChanged:
            return .red
        }
    }

    fileprivate var securityTitle: String {
        switch self {
        case .unverified:
            return "Not verified"
        case .verified:
            return "Verified on this device"
        case .keyChanged:
            return "Safety number changed"
        }
    }

    fileprivate func securityExplanation(contactName: String) -> String {
        switch self {
        case .unverified:
            return "Sending and authenticated playback stay paused until you verify \(contactName)’s current device identity."
        case .verified:
            return "The current device identity matches the identity you verified with \(contactName). Verify again if either person changes devices or reinstalls Kithra."
        case .keyChanged:
            return "Stop. \(contactName)’s device identity no longer matches the one you verified. Confirm the new safety number through a trusted channel before continuing."
        }
    }
}
