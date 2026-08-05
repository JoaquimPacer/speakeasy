import SwiftUI
import UIKit

struct RecordingPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var selectedQuality: DeliveryVideoQuality = .compact480p
    @State private var selectedContactID: UUID?
    @State private var rawVideoURL: URL?
    @State private var activeSendURL: URL?
    @State private var hasDisappeared = false
    @State private var showingVideoRecorder = false
    @State private var didAutoLaunchRecorder = false

    let contact: Contact?
    var autoLaunchRecorder = false
    var autoSendAfterCapture = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black)
                VStack(spacing: 12) {
                    Image(systemName: rawVideoURL == nil ? "video" : "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(rawVideoURL == nil ? "Ready to record" : "Ready to send")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxWidth: 360)
            .padding(.top)

            if contact == nil, !appState.contacts.isEmpty {
                Picker("Contact", selection: $selectedContactID) {
                    ForEach(appState.contacts) { contact in
                        Text(contact.displayName).tag(Optional(contact.contactID))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360)
            }

            if let selectedContact, selectedContactTrustState != .verified {
                NavigationLink {
                    ContactSecurityView(contact: selectedContact)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedContactTrustState == .keyChanged
                              ? "exclamationmark.shield.fill"
                              : "shield")
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedContactTrustState == .keyChanged
                                 ? "Safety number changed"
                                 : "Verify before recording")
                                .font(.subheadline.weight(.semibold))
                            Text("Compare the safety number or scan both QR codes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                    .padding(12)
                    .background(
                        selectedContactTrustState == .keyChanged
                            ? Color.red.opacity(0.1)
                            : Color.orange.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                selectedContactTrustState == .keyChanged ? Color.red : Color.orange,
                                lineWidth: selectedContactTrustState == .keyChanged ? 2 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 360)
                .accessibilityHint("Opens contact security")
            }

            Picker("Quality", selection: $selectedQuality) {
                ForEach(DeliveryVideoQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            HStack(spacing: 18) {
                Button {
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Switch camera")
                .disabled(true)

                Button {
                    showingVideoRecorder = true
                } label: {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel("Record video")
                .accessibilityHint(recordingDisabledHint)
                .disabled(
                    selectedContact == nil ||
                        selectedContactTrustState != .verified ||
                        appState.isWorking
                )

                Button {
                    send(rawVideoURL)
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Send video")
                .accessibilityHint(recordingDisabledHint)
                .disabled(
                    rawVideoURL == nil ||
                        selectedContact == nil ||
                        selectedContactTrustState != .verified ||
                        appState.isWorking
                )
            }

            if let error = appState.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
        .navigationTitle(contact.map { "Record for \($0.displayName)" } ?? "Record")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if appState.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .fullScreenCover(isPresented: $showingVideoRecorder, onDismiss: {
            hasDisappeared = false
        }) {
            VideoRecorderView(
                onFinish: { url in
                    if let previousURL = rawVideoURL,
                       previousURL != url,
                       previousURL != activeSendURL {
                        Task {
                            await appState.mediaPipeline.cleanupTemporaryFiles([previousURL])
                        }
                    }
                    rawVideoURL = url
                    showingVideoRecorder = false
                    if autoSendAfterCapture {
                        send(url)
                    }
                },
                onCancel: {
                    showingVideoRecorder = false
                }
            )
            .ignoresSafeArea()
        }
        .onAppear {
            hasDisappeared = false
            selectedContactID = contact?.contactID ?? selectedContactID ?? appState.contacts.first?.contactID
            autoLaunchIfNeeded()
        }
        .onDisappear {
            hasDisappeared = true
            guard let retainedURL = rawVideoURL,
                  retainedURL != activeSendURL else {
                return
            }
            rawVideoURL = nil
            Task {
                await appState.mediaPipeline.cleanupTemporaryFiles([retainedURL])
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }
        }
    }

    private func autoLaunchIfNeeded() {
        guard autoLaunchRecorder,
              !didAutoLaunchRecorder,
              selectedContact != nil,
              selectedContactTrustState == .verified else {
            return
        }

        didAutoLaunchRecorder = true
        DispatchQueue.main.async {
            showingVideoRecorder = true
        }
    }

    private func send(_ videoURL: URL?) {
        guard let videoURL, let selectedContact else {
            return
        }

        activeSendURL = videoURL
        Task {
            await appState.sendVideo(
                rawVideoURL: videoURL,
                quality: selectedQuality,
                to: selectedContact
            )
            let succeeded = appState.lastErrorMessage == nil
            activeSendURL = nil
            if succeeded || hasDisappeared {
                await appState.mediaPipeline.cleanupTemporaryFiles([videoURL])
                if rawVideoURL == videoURL {
                    rawVideoURL = nil
                }
            }
            if succeeded {
                dismiss()
            }
        }
    }

    private var selectedContact: Contact? {
        if let contact {
            return appState.contacts.first { $0.contactID == contact.contactID } ?? contact
        }
        guard let selectedContactID else {
            return appState.contacts.first
        }
        return appState.contacts.first { $0.contactID == selectedContactID }
    }

    private var selectedContactTrustState: ContactTrustState {
        guard let selectedContact else {
            return .unverified
        }
        return appState.trustState(for: selectedContact)
    }

    private var recordingDisabledHint: String {
        switch selectedContactTrustState {
        case .verified:
            return ""
        case .unverified:
            return "Verify this contact before recording or sending"
        case .keyChanged:
            return "Verify the changed safety number before recording or sending"
        }
    }
}

struct RecordingPlaceholderView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            RecordingPlaceholderView(contact: PreviewData.sample.contacts[0])
        }
        .environmentObject(AppState())
    }
}

private struct VideoRecorderView: UIViewControllerRepresentable {
    var onFinish: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.mediaTypes = ["public.movie"]
        picker.videoMaximumDuration = 120
        picker.videoQuality = .typeMedium

        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .video
            picker.cameraDevice = .front
        } else {
            picker.sourceType = .photoLibrary
        }

        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onFinish: (URL) -> Void
        private let onCancel: () -> Void

        init(onFinish: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let url = info[.mediaURL] as? URL else {
                onCancel()
                return
            }

            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
                onFinish(url)
            } catch {
                // The picker returns a temporary movie URL. If it cannot be
                // protected, discard it rather than retaining plaintext media.
                try? FileManager.default.removeItem(at: url)
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
