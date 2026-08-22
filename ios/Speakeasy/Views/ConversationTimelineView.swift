@preconcurrency import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct ConversationTimelineView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @StateObject private var recorder = InlineVideoRecorder()
    @State private var inlinePlayback: InlinePlayback?
    @State private var selectedMessageID: UUID?
    @State private var showingContactSecurity = false
    @State private var playbackRequestID: UUID?

    let contact: Contact

    private var currentContact: Contact {
        appState.contacts.first { $0.contactID == contact.contactID } ?? contact
    }

    private var trustState: ContactTrustState {
        appState.trustState(for: currentContact)
    }

    private var messages: [Message] {
        appState.messages(for: contact)
    }

    private var messageIDs: [UUID] {
        messages.map(\.id)
    }

    private var isScreenshotPreview: Bool {
#if DEBUG
        appState.isScreenshotPreview
#else
        false
#endif
    }

    var body: some View {
        ZStack {
            cameraBackdrop

            VStack(spacing: 0) {
                header
                    .padding(.top, 12)
                    .padding(.horizontal, 18)

                if trustState != .verified, inlinePlayback == nil {
                    verificationNotice
                        .padding(.top, 12)
                        .padding(.horizontal, 18)
                }

                Spacer(minLength: 24)

                if inlinePlayback == nil {
                    recordButton
                        .padding(.bottom, 18)
                }

                historyStrip
            }

            if appState.isWorking {
                sendingOverlay
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            recorder.onFinishedRecording = { url, releaseOwnership in
                sendRecordedVideo(url, releaseOwnership: releaseOwnership)
            }
            if scenePhase == .active, !isScreenshotPreview {
                recorder.prepare()
            }
        }
        .onDisappear {
            recorder.stopSession()
            clearInlinePlayback()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if !isScreenshotPreview {
                    recorder.prepare()
                }
            case .inactive, .background:
                // Mark the current recording generation discarded before the
                // capture queue can start or finish another segment.
                recorder.stopSession()
                clearInlinePlayback()
            @unknown default:
                recorder.stopSession()
                clearInlinePlayback()
            }
        }
        .onChange(of: appState.activePlaybackFile?.id) { activePlaybackID in
            guard let inlinePlayback,
                  inlinePlayback.file.id != activePlaybackID else {
                return
            }
            self.inlinePlayback = nil
            selectedMessageID = nil
            playbackRequestID = nil
            if scenePhase == .active, !isScreenshotPreview {
                recorder.prepare()
            }
        }
        .task(id: contact.id) {
            if !isScreenshotPreview {
                await appState.refreshQuietly()
            }
        }
        .sheet(isPresented: $showingContactSecurity, onDismiss: {
            if !isScreenshotPreview {
                recorder.prepare()
            }
        }) {
            NavigationStack {
                ContactSecurityView(contact: currentContact)
            }
            .environmentObject(appState)
        }
    }

    private var cameraBackdrop: some View {
        ZStack {
            if let inlinePlayback {
                InlinePlaybackView(
                    file: inlinePlayback.file,
                    onStarted: {
                        Task {
                            await appState.markMessageWatched(
                                messageID: inlinePlayback.messageID
                            )
                        }
                    },
                    onEnded: {
                        playNextAfterCurrent()
                    }
                )
                    .id(inlinePlayback.id)
                    .ignoresSafeArea()
            } else {
                if isScreenshotPreview {
                    screenshotPreviewBackdrop
                } else {
                    CameraPreview(session: recorder.session)
                        .ignoresSafeArea()
                        .opacity(recorder.isReady ? 1 : 0)
                }
            }

            if !recorder.isReady, inlinePlayback == nil, !isScreenshotPreview {
                LinearGradient(
                    colors: [
                        Color.black,
                        Color(red: 0.04, green: 0.05, blue: 0.06),
                        Color(red: 0.10, green: 0.12, blue: 0.11)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 14) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 58, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.16))
                    Text(recorder.statusText)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                .padding(.bottom, 130)
            }

            if inlinePlayback == nil {
                Color.black
                    .opacity(recorder.isRecording ? 0.04 : 0.18)
                    .ignoresSafeArea()
            }
        }
    }

    private var screenshotPreviewBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.08),
                    Color(red: 0.08, green: 0.16, blue: 0.18),
                    Color(red: 0.10, green: 0.24, blue: 0.21)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: 290, height: 290)
                .blur(radius: 4)

            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Text("Private video")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Tap record to send an end-to-end encrypted video.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.76))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 250)
            }
            .padding(.bottom, 116)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Back")

            Spacer()

            VStack(spacing: 8) {
                Text(currentContact.displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Button {
                    openContactSecurity()
                } label: {
                    ContactTrustBadge(state: trustState)
                }
                .buttonStyle(.plain)
                .disabled(recorder.isRecording || appState.isWorking)
                .accessibilityHint("Opens safety-number and QR-code verification")

                if recorder.isRecording {
                    Label("Recording", systemImage: "circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(red: 0.95, green: 0.27, blue: 0.42), in: Capsule())
                } else {
                    Text(statusText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                }
            }
            .frame(maxWidth: 220)
            .padding(.top, 3)

            Spacer()

            if inlinePlayback == nil {
                Button {
                    recorder.flipCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Switch camera")
                .disabled(!recorder.canFlipCamera || appState.isWorking)
                .opacity(recorder.canFlipCamera ? 1 : 0)
            } else {
                Button {
                    clearInlinePlayback()
                } label: {
                    Image(systemName: "video.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Return to camera")
            }
        }
    }

    private var recordButton: some View {
        Button {
            clearInlinePlayback()
            guard !isScreenshotPreview else {
                return
            }
            recorder.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color(red: 0.95, green: 0.27, blue: 0.42) : .white)
                    .frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 12)

                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "video.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record video")
        .accessibilityHint(recordingAccessibilityHint)
        .disabled(
            (!recorder.isReady && !isScreenshotPreview) ||
                appState.isWorking ||
                (!recorder.isRecording && trustState != .verified)
        )
    }

    private var verificationNotice: some View {
        Button {
            openContactSecurity()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: trustState == .keyChanged ? "exclamationmark.shield.fill" : "shield")
                    .font(.title3.weight(.semibold))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(trustState == .keyChanged ? "Safety number changed" : "Verify before recording")
                        .font(.subheadline.weight(.semibold))
                    Text(trustState == .keyChanged
                         ? "Confirm the new identity before continuing."
                         : "Compare the safety number or scan both QR codes.")
                        .font(.caption)
                        .opacity(0.86)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(
                trustState == .keyChanged ? Color.red.opacity(0.86) : Color.orange.opacity(0.82),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .disabled(recorder.isRecording || appState.isWorking)
        .accessibilityHint("Opens contact security")
    }

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            if messages.isEmpty {
                Text("No videos yet")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, minHeight: 136)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(messages) { message in
                                VideoHistoryTile(
                                    message: message,
                                    direction: message.direction(for: appState.currentUser?.id),
                                    isSelected: message.id == selectedMessageID,
                                    onPlay: {
                                        play(message)
                                    }
                                )
                                .id(message.id)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    .onAppear {
                        scrollToLatest(in: proxy, animated: false)
                    }
                    .onChange(of: messageIDs) { _ in
                        scrollToLatest(in: proxy, animated: true)
                    }
                    .onChange(of: selectedMessageID) { selectedID in
                        guard let selectedID else {
                            return
                        }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.black.opacity(0.86))
    }

    private var sendingOverlay: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusText: String {
        if isScreenshotPreview {
            guard let latest = messages.last else {
                return "Ready"
            }
            let prefix = latest.direction(for: appState.currentUser?.id) == .sent
                ? "Sent"
                : "Received"
            return "\(prefix) \(latest.createdAt.relativeShortDisplay)"
        }
        if let error = recorder.errorMessage {
            return error
        }
        if recorder.statusText != "Ready", !recorder.isRecording {
            return recorder.statusText
        }

        guard let latest = messages.last else {
            return "Ready"
        }

        let prefix = latest.direction(for: appState.currentUser?.id) == .sent ? "Sent" : "Received"
        return "\(prefix) \(latest.createdAt.relativeShortDisplay)"
    }

    private func sendRecordedVideo(
        _ url: URL,
        releaseOwnership: @escaping () -> Void
    ) {
        Task {
            await appState.sendVideo(
                rawVideoURL: url,
                quality: .compact480p,
                to: currentContact,
                onPlaintextOwnershipAccepted: releaseOwnership
            )
            await appState.refreshQuietly()
        }
    }

    private var recordingAccessibilityHint: String {
        guard !recorder.isRecording, trustState != .verified else {
            return ""
        }
        return trustState == .keyChanged
            ? "Recording is paused until you verify the changed safety number"
            : "Recording is paused until you verify this contact"
    }

    private func openContactSecurity() {
        guard !recorder.isRecording else {
            return
        }
        clearInlinePlayback()
        recorder.stopSession()
        showingContactSecurity = true
    }

    private func play(_ message: Message) {
        let requestID = UUID()
        playbackRequestID = requestID
        inlinePlayback = nil
        selectedMessageID = nil
        Task {
            await appState.discardActivePlaybackFile()
            guard playbackRequestID == requestID else {
                return
            }
            guard let playbackFile = await appState.preparePlayback(message: message) else {
                return
            }
            guard playbackRequestID == requestID,
                  appState.activePlaybackFile?.id == playbackFile.id else {
                if appState.activePlaybackFile?.id == playbackFile.id {
                    await appState.discardActivePlaybackFile()
                } else {
                    await appState.mediaPipeline.cleanupTemporaryFiles([playbackFile.url])
                }
                return
            }
            selectedMessageID = message.id
            inlinePlayback = InlinePlayback(messageID: message.id, file: playbackFile)
        }
    }

    private func playNextAfterCurrent() {
        guard let selectedMessageID,
              let currentIndex = messages.firstIndex(where: { $0.id == selectedMessageID }) else {
            return
        }

        let nextIndex = messages.index(after: currentIndex)
        guard nextIndex < messages.endIndex else {
            return
        }

        play(messages[nextIndex])
    }

    private func clearInlinePlayback() {
        playbackRequestID = nil
        inlinePlayback = nil
        selectedMessageID = nil
        Task {
            await appState.discardActivePlaybackFile()
        }
    }

    private func scrollToLatest(in proxy: ScrollViewProxy, animated: Bool) {
        guard let latestID = messages.last?.id else {
            return
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(latestID, anchor: .trailing)
                }
            } else {
                proxy.scrollTo(latestID, anchor: .trailing)
            }
        }
    }
}

private struct InlinePlayback: Identifiable, Hashable {
    let id: UUID
    var messageID: UUID
    var file: PlaybackTempFile

    init(messageID: UUID, file: PlaybackTempFile) {
        self.id = file.id
        self.messageID = messageID
        self.file = file
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("PreviewView must be backed by AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}

/// Tracks each inline capture from the user's tap through AVFoundation's
/// asynchronous start/finish callbacks and any segment merge. A background
/// discard is generation based, so even a callback that arrives after the app
/// leaves the foreground cannot publish its plaintext output.
struct InlineRecordingInvalidation {
    let generation: UInt64
    let outputURLs: [URL]
}

final class InlineRecordingLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var discardedGenerations: Set<UInt64> = []
    private var generationByOutputPath: [String: UInt64] = [:]
    private var outputURLsByGeneration: [UInt64: [String: URL]] = [:]
    private var cancellationsByGeneration: [UInt64: [UUID: @Sendable () -> Void]] = [:]

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        discardedGenerations.remove(nextGeneration)
        return nextGeneration
    }

    @discardableResult
    func registerOutput(_ url: URL, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation,
              !discardedGenerations.contains(generation) else {
            return false
        }
        let canonicalURL = url.standardizedFileURL
        generationByOutputPath[canonicalURL.path] = generation
        outputURLsByGeneration[generation, default: [:]][canonicalURL.path] = canonicalURL
        return true
    }

    func generation(for url: URL) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return generationByOutputPath[url.standardizedFileURL.path]
    }

    var currentGeneration: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration
    }

    func takeGeneration(for url: URL) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return generationByOutputPath.removeValue(
            forKey: url.standardizedFileURL.path
        )
    }

    func beginOperation(
        outputURL: URL,
        generation: UInt64,
        cancellation: @escaping @Sendable () -> Void
    ) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation,
              !discardedGenerations.contains(generation) else {
            return nil
        }
        let canonicalURL = outputURL.standardizedFileURL
        outputURLsByGeneration[generation, default: [:]][canonicalURL.path] = canonicalURL
        let operationID = UUID()
        cancellationsByGeneration[generation, default: [:]][operationID] = cancellation
        return operationID
    }

    func finishOperation(_ operationID: UUID, generation: UInt64) {
        lock.lock()
        cancellationsByGeneration[generation]?[operationID] = nil
        lock.unlock()
    }

    func startOperation(
        _ operationID: UUID,
        generation: UInt64,
        start: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation,
              !discardedGenerations.contains(generation),
              cancellationsByGeneration[generation]?[operationID] != nil else {
            return false
        }
        start()
        return true
    }

    @discardableResult
    func discardActive() -> InlineRecordingInvalidation? {
        lock.lock()
        guard let activeGeneration else {
            lock.unlock()
            return nil
        }
        discardedGenerations.insert(activeGeneration)
        let outputURLs = Array(outputURLsByGeneration[activeGeneration, default: [:]].values)
        let cancellations = Array(cancellationsByGeneration[activeGeneration, default: [:]].values)
        cancellationsByGeneration[activeGeneration] = [:]
        lock.unlock()

        cancellations.forEach { $0() }
        return InlineRecordingInvalidation(
            generation: activeGeneration,
            outputURLs: outputURLs
        )
    }

    func isDiscarded(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return discardedGenerations.contains(generation)
    }

    func complete(_ generation: UInt64) {
        lock.lock()
        if activeGeneration == generation {
            activeGeneration = nil
        }
        discardedGenerations.remove(generation)
        generationByOutputPath = generationByOutputPath.filter { $0.value != generation }
        outputURLsByGeneration[generation] = nil
        cancellationsByGeneration[generation] = nil
        lock.unlock()
    }
}

private final class InlineVideoRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onFinishedRecording: ((URL, @escaping () -> Void) -> Void)?

    @Published private(set) var canFlipCamera = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var statusText = "Preparing camera"

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.joaquimpacer.kithra.camera")
    private var activeCameraPosition: AVCaptureDevice.Position = .front
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var didConfigureSession = false
    private var isDiscardingRecording = false
    private var isStoppingForFinalSend = false
    private var isSwitchingCameraDuringRecording = false
    private var segmentURLs: [URL] = []
    private var durationBudget = RecordingDurationBudget()
    private let plaintextTempJanitor = KithraPlaintextTempFileJanitor.shared
    private let recordingLifecycle = InlineRecordingLifecycle()

    func prepare() {
        guard !didConfigureSession else {
            startSessionIfNeeded()
            return
        }

        statusText = "Checking camera access"
        requestAccess(for: .video) { [weak self] cameraGranted in
            guard let self else { return }
            guard cameraGranted else {
                self.updateOnMain {
                    self.errorMessage = "Camera access is required"
                    self.statusText = "Camera access is required"
                }
                return
            }

            self.requestAccess(for: .audio) { [weak self] microphoneGranted in
                guard let self else { return }
                guard microphoneGranted else {
                    self.updateOnMain {
                        self.errorMessage = "Microphone access is required"
                        self.statusText = "Microphone access is required"
                    }
                    return
                }

                self.configureSession()
            }
        }
    }

    func toggleRecording() {
        isRecording ? stopRecordingForSend() : startRecordingSession()
    }

    func flipCamera() {
        guard canFlipCamera, !isSwitchingCameraDuringRecording else {
            return
        }

        if isRecording {
            isSwitchingCameraDuringRecording = true
            statusText = "Switching camera"
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.movieOutput.isRecording {
                    self.movieOutput.stopRecording()
                } else {
                    self.resumeAfterCameraFlip()
                }
            }
            return
        }

        switchCamera()
    }

    private func switchCamera(completion: (() -> Void)? = nil) {
        activeCameraPosition = activeCameraPosition == .front ? .back : .front
        replaceVideoInput(completion: completion)
    }

    func stopSession() {
        let invalidation = recordingLifecycle.discardActive()
        isDiscardingRecording = invalidation != nil
        isRecording = false
        if let invalidation {
            Self.cleanupRecordingFiles(invalidation.outputURLs)
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func startSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func startRecordingSession() {
        guard isReady,
              !movieOutput.isRecording,
              recordingLifecycle.currentGeneration == nil else {
            return
        }

        errorMessage = nil
        isDiscardingRecording = false
        isStoppingForFinalSend = false
        isSwitchingCameraDuringRecording = false
        for staleSegmentURL in segmentURLs {
            Self.cleanupRecordingFiles([staleSegmentURL])
        }
        segmentURLs.removeAll()
        durationBudget.reset()
        let generation = recordingLifecycle.begin()
        // Establish intent before dispatching startRecording. Backgrounding in
        // this window must mark the generation discarded even if AVFoundation
        // has not delivered didStartRecording yet.
        isRecording = true
        startRecordingSegment(generation: generation)
    }

    private func startRecordingSegment(generation: UInt64) {
        let remainingDuration = durationBudget.remainingSeconds
        guard remainingDuration > 0 else {
            finishRecordedSegments(generation: generation)
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        do {
            try plaintextTempJanitor.beginProducing([url])
        } catch {
            resetRecordingState(completing: generation)
            return
        }
        guard recordingLifecycle.registerOutput(url, generation: generation) else {
            Self.cleanupRecordingFiles([url])
            plaintextTempJanitor.finishProducing([url])
            resetRecordingState(completing: generation)
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else {
                Self.cleanupRecordingFiles([url])
                KithraPlaintextTempFileJanitor.shared.finishProducing([url])
                return
            }
            guard !self.recordingLifecycle.isDiscarded(generation),
                  !self.movieOutput.isRecording else {
                _ = self.recordingLifecycle.takeGeneration(for: url)
                Self.cleanupRecordingFiles([url])
                self.plaintextTempJanitor.finishProducing([url])
                if self.recordingLifecycle.isDiscarded(generation) {
                    self.updateOnMain {
                        self.resetRecordingState(completing: generation)
                    }
                }
                return
            }

            self.applyVideoConnectionSettings()
            self.movieOutput.maxRecordedDuration = CMTime(
                seconds: remainingDuration,
                preferredTimescale: 600
            )
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func stopRecordingForSend() {
        isStoppingForFinalSend = true
        statusText = "Preparing video"

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else if let generation = self.recordingLifecycle.currentGeneration {
                self.finishRecordedSegments(generation: generation)
            }
        }
    }

    private func requestAccess(
        for mediaType: AVMediaType,
        completion: @escaping (Bool) -> Void
    ) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType, completionHandler: completion)
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    private func configureSession(reset: Bool = false, completion: (() -> Void)? = nil) {
        updateOnMain {
            self.statusText = "Starting camera"
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                self.session.beginConfiguration()
                if reset {
                    self.session.inputs.forEach { self.session.removeInput($0) }
                    self.session.outputs.forEach { self.session.removeOutput($0) }
                    self.videoInput = nil
                    self.audioInput = nil
                    self.didConfigureSession = false
                }

                self.session.sessionPreset = .high

                let videoDevice = try self.cameraDevice(position: self.activeCameraPosition)
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                guard self.session.canAddInput(videoInput) else {
                    throw CameraRecorderError.cannotAddVideoInput
                }
                self.session.addInput(videoInput)
                self.videoInput = videoInput

                if let audioDevice = AVCaptureDevice.default(for: .audio) {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if self.session.canAddInput(audioInput) {
                        self.session.addInput(audioInput)
                        self.audioInput = audioInput
                    }
                }

                guard self.session.canAddOutput(self.movieOutput) else {
                    throw CameraRecorderError.cannotAddMovieOutput
                }
                self.session.addOutput(self.movieOutput)
                self.movieOutput.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
                self.applyVideoConnectionSettings()
                self.session.commitConfiguration()
                self.didConfigureSession = true

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                let canFlip = self.availableCameraPositions().count > 1
                self.updateOnMain {
                    self.canFlipCamera = canFlip
                    self.errorMessage = nil
                    self.isReady = true
                    self.statusText = self.isRecording ? "Recording" : "Ready"
                    completion?()
                }
            } catch {
                self.session.commitConfiguration()
                self.updateOnMain {
                    self.isSwitchingCameraDuringRecording = false
                    self.errorMessage = error.localizedDescription
                    self.isReady = false
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    private func replaceVideoInput(completion: (() -> Void)? = nil) {
        updateOnMain {
            self.statusText = "Switching camera"
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                self.session.beginConfiguration()

                if let videoInput = self.videoInput {
                    self.session.removeInput(videoInput)
                    self.videoInput = nil
                }

                let videoDevice = try self.cameraDevice(position: self.activeCameraPosition)
                let replacementInput = try AVCaptureDeviceInput(device: videoDevice)
                guard self.session.canAddInput(replacementInput) else {
                    throw CameraRecorderError.cannotAddVideoInput
                }
                self.session.addInput(replacementInput)
                self.videoInput = replacementInput
                self.applyVideoConnectionSettings()
                self.session.commitConfiguration()

                let canFlip = self.availableCameraPositions().count > 1
                self.updateOnMain {
                    self.canFlipCamera = canFlip
                    self.errorMessage = nil
                    self.isReady = true
                    self.statusText = self.isRecording ? "Recording" : "Ready"
                    completion?()
                }
            } catch {
                self.session.commitConfiguration()
                self.updateOnMain {
                    self.isSwitchingCameraDuringRecording = false
                    self.errorMessage = error.localizedDescription
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    private func resumeAfterCameraFlip() {
        updateOnMain {
            self.switchCamera {
                self.isSwitchingCameraDuringRecording = false
                if self.isDiscardingRecording {
                    self.resetRecordingState(
                        completing: self.recordingLifecycle.currentGeneration
                    )
                } else if self.isStoppingForFinalSend {
                    if let generation = self.recordingLifecycle.currentGeneration {
                        self.finishRecordedSegments(generation: generation)
                    }
                } else if self.isRecording,
                          let generation = self.recordingLifecycle.currentGeneration {
                    self.startRecordingSegment(generation: generation)
                }
            }
        }
    }

    private func finishRecordedSegments(generation: UInt64) {
        updateOnMain {
            let segments = self.segmentURLs
            self.segmentURLs.removeAll()
            self.isRecording = false
            self.isStoppingForFinalSend = false
            self.isSwitchingCameraDuringRecording = false
            self.statusText = "Preparing video"

            Task { [weak self] in
                do {
                    guard let self else {
                        Self.cleanupRecordingFiles(segments)
                        return
                    }
                    let outputURL = try await Self.combineSegments(
                        segments,
                        generation: generation,
                        lifecycle: self.recordingLifecycle
                    )
                    DispatchQueue.main.async { [weak self] in
                        guard let self else {
                            Self.cleanupRecordingFiles([outputURL])
                            return
                        }
                        guard let onFinishedRecording = self.onFinishedRecording else {
                            Self.cleanupRecordingFiles([outputURL])
                            self.resetRecordingState(completing: generation)
                            return
                        }
                        guard !self.recordingLifecycle.isDiscarded(generation) else {
                            Self.cleanupRecordingFiles([outputURL])
                            self.resetRecordingState(completing: generation)
                            return
                        }
                        self.statusText = "Ready"
                        onFinishedRecording(outputURL) { [weak self] in
                            self?.recordingLifecycle.complete(generation)
                        }
                    }
                } catch {
                    let wasDiscarded = self?.recordingLifecycle.isDiscarded(generation) ?? true
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.recordingLifecycle.complete(generation)
                        if !wasDiscarded {
                            self.errorMessage = error.localizedDescription
                        }
                        self.statusText = "Ready"
                    }
                }
            }
        }
    }

    private func resetRecordingState(completing generation: UInt64? = nil) {
        let cleanupURLs = segmentURLs
        segmentURLs.removeAll()
        isDiscardingRecording = false
        isStoppingForFinalSend = false
        isSwitchingCameraDuringRecording = false
        isRecording = false
        statusText = "Ready"
        durationBudget.reset()
        Self.cleanupRecordingFiles(cleanupURLs)
        if let generation {
            recordingLifecycle.complete(generation)
        }
    }

    private static func combineSegments(
        _ segments: [URL],
        generation: UInt64,
        lifecycle: InlineRecordingLifecycle
    ) async throws -> URL {
        guard let firstSegment = segments.first else {
            throw MediaPipelineError.exportFailed
        }
        guard segments.count > 1 else {
            guard !lifecycle.isDiscarded(generation) else {
                cleanupRecordingFiles([firstSegment])
                throw MediaPipelineError.plaintextProductionInvalidated
            }
            return firstSegment
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-merged-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try KithraPlaintextTempFileJanitor.shared.beginProducing([outputURL])
        defer {
            KithraPlaintextTempFileJanitor.shared.finishProducing([outputURL])
        }

        do {
            let sourceSegments = try segments.map { segmentURL in
                let asset = AVURLAsset(url: segmentURL)
                guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                    throw MediaPipelineError.exportFailed
                }
                return RecordedMovieSegment(
                    url: segmentURL,
                    asset: asset,
                    duration: asset.duration,
                    videoTrack: videoTrack,
                    audioTrack: asset.tracks(withMediaType: .audio).first,
                    renderSize: displaySize(for: videoTrack)
                )
            }
            let renderSize = sourceSegments.reduce(sourceSegments[0].renderSize) { partial, segment in
                CGSize(
                    width: max(partial.width, segment.renderSize.width),
                    height: max(partial.height, segment.renderSize.height)
                )
            }

            let composition = AVMutableComposition()
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw MediaPipelineError.exportFailed
            }
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )

            var cursor = CMTime.zero
            var instructions: [AVVideoCompositionInstructionProtocol] = []
            for segment in sourceSegments {
                let range = CMTimeRange(start: .zero, duration: segment.duration)
                try compositionVideoTrack.insertTimeRange(range, of: segment.videoTrack, at: cursor)

                if let sourceAudioTrack = segment.audioTrack,
                   let compositionAudioTrack {
                    try compositionAudioTrack.insertTimeRange(range, of: sourceAudioTrack, at: cursor)
                }

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: cursor, duration: segment.duration)
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
                layerInstruction.setTransform(
                    playbackTransform(for: segment.videoTrack, renderSize: renderSize),
                    at: cursor
                )
                instruction.layerInstructions = [layerInstruction]
                instructions.append(instruction)

                cursor = CMTimeAdd(cursor, segment.duration)
            }

            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw MediaPipelineError.exportSessionUnavailable
            }
            let exportBox = SendableMovieExportSession(exportSession)
            exportBox.session.outputURL = outputURL
            exportBox.session.outputFileType = .mov
            exportBox.session.shouldOptimizeForNetworkUse = true
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = renderSize
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            videoComposition.instructions = instructions
            exportBox.session.videoComposition = videoComposition

            guard let operationID = lifecycle.beginOperation(
                outputURL: outputURL,
                generation: generation,
                cancellation: { exportBox.session.cancelExport() }
            ) else {
                exportBox.session.cancelExport()
                cleanupRecordingFiles(segments + [outputURL])
                throw MediaPipelineError.plaintextProductionInvalidated
            }

            return try await withCheckedThrowingContinuation { continuation in
                let didStart = lifecycle.startOperation(
                    operationID,
                    generation: generation
                ) {
                    exportBox.session.exportAsynchronously {
                        lifecycle.finishOperation(operationID, generation: generation)
                        guard !lifecycle.isDiscarded(generation) else {
                            cleanupRecordingFiles(segments + [outputURL])
                            continuation.resume(
                                throwing: MediaPipelineError.plaintextProductionInvalidated
                            )
                            return
                        }
                        switch exportBox.session.status {
                        case .completed:
                            do {
                                try FileManager.default.setAttributes(
                                    [.protectionKey: FileProtectionType.complete],
                                    ofItemAtPath: outputURL.path
                                )
                                cleanupRecordingFiles(segments)
                                continuation.resume(returning: outputURL)
                            } catch {
                                cleanupRecordingFiles(segments + [outputURL])
                                continuation.resume(throwing: error)
                            }
                        case .cancelled:
                            cleanupRecordingFiles(segments + [outputURL])
                            continuation.resume(throwing: MediaPipelineError.exportCancelled)
                        case .failed:
                            cleanupRecordingFiles(segments + [outputURL])
                            continuation.resume(
                                throwing: exportBox.session.error ?? MediaPipelineError.exportFailed
                            )
                        default:
                            cleanupRecordingFiles(segments + [outputURL])
                            continuation.resume(throwing: MediaPipelineError.exportFailed)
                        }
                    }
                }
                guard didStart else {
                    lifecycle.finishOperation(operationID, generation: generation)
                    cleanupRecordingFiles(segments + [outputURL])
                    continuation.resume(
                        throwing: MediaPipelineError.plaintextProductionInvalidated
                    )
                    return
                }
            }
        } catch {
            cleanupRecordingFiles(segments + [outputURL])
            throw error
        }
    }

    private static func cleanupRecordingFiles(_ urls: [URL]) {
        for url in urls {
            let canonicalURL = url.standardizedFileURL
            guard KithraPlaintextTempFileJanitor.ownsInlineRecordingFile(
                canonicalURL,
                applicationTemporaryRoot: FileManager.default.temporaryDirectory
            ) else {
                assertionFailure("Refusing to delete an unowned recording path: \(canonicalURL.path)")
                continue
            }
            KithraPlaintextTempFileJanitor.shared.release(canonicalURL)
            if FileManager.default.fileExists(atPath: canonicalURL.path) {
                let values = try? canonicalURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ])
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true else {
                    assertionFailure("Refusing to delete non-regular recording media")
                    continue
                }
                try? FileManager.default.removeItem(at: canonicalURL)
            }
        }
    }

    private static func displaySize(for track: AVAssetTrack) -> CGSize {
        let transformedRect = CGRect(origin: .zero, size: track.naturalSize)
            .applying(track.preferredTransform)
        return CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )
    }

    private static func playbackTransform(for track: AVAssetTrack, renderSize: CGSize) -> CGAffineTransform {
        let naturalRect = CGRect(origin: .zero, size: track.naturalSize)
        let transformedRect = naturalRect.applying(track.preferredTransform)
        let displaySize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )
        let scale = min(renderSize.width / displaySize.width, renderSize.height / displaySize.height)
        let scaledSize = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        let centerOffset = CGPoint(
            x: (renderSize.width - scaledSize.width) / 2,
            y: (renderSize.height - scaledSize.height) / 2
        )

        return track.preferredTransform
            .concatenating(CGAffineTransform(translationX: -transformedRect.origin.x, y: -transformedRect.origin.y))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: centerOffset.x, y: centerOffset.y))
    }

    private func cameraDevice(position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
        if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return camera
        }
        if let camera = AVCaptureDevice.default(for: .video) {
            return camera
        }
        throw CameraRecorderError.cameraUnavailable
    }

    private func availableCameraPositions() -> [AVCaptureDevice.Position] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map(\.position)
    }

    private func applyVideoConnectionSettings() {
        guard let connection = movieOutput.connection(with: .video) else {
            return
        }

        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = activeCameraPosition == .front
        }
    }

    private func updateOnMain(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        guard let generation = recordingLifecycle.generation(for: fileURL),
              !recordingLifecycle.isDiscarded(generation) else {
            if movieOutput.isRecording {
                movieOutput.stopRecording()
            }
            return
        }
        updateOnMain {
            guard !self.recordingLifecycle.isDiscarded(generation) else {
                return
            }
            self.errorMessage = nil
            self.isRecording = true
            self.statusText = "Recording"
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        defer { plaintextTempJanitor.finishProducing([outputFileURL]) }
        let generation = recordingLifecycle.takeGeneration(for: outputFileURL)
        let shouldDiscard = generation.map(recordingLifecycle.isDiscarded) ?? true
        let shouldResumeAfterFlip = isSwitchingCameraDuringRecording && !shouldDiscard
        let shouldFinishForSend = isStoppingForFinalSend && !shouldDiscard
        var recordingError: String?

        if shouldDiscard {
            // AVFoundation may recreate/finish the file after stopSession's
            // early unlink. Remove it directly on the delegate callback before
            // dispatching any UI reset that might be suspended in background.
            Self.cleanupRecordingFiles([outputFileURL])
            updateOnMain {
                self.resetRecordingState(
                    completing: generation ?? self.recordingLifecycle.currentGeneration
                )
            }
            return
        }

        if let error {
            let nsError = error as NSError
            let finished = (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if !finished {
                recordingError = error.localizedDescription
            }
        }

        if recordingError == nil {
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: outputFileURL.path
                )
            } catch {
                recordingError = error.localizedDescription
            }
        }
        if recordingError != nil {
            Self.cleanupRecordingFiles([outputFileURL])
        }
        let segmentDuration = recordingError == nil
            ? CMTimeGetSeconds(AVURLAsset(url: outputFileURL).duration)
            : 0

        updateOnMain {
            if let recordingError {
                self.errorMessage = recordingError
                if shouldResumeAfterFlip {
                    self.resumeAfterCameraFlip()
                } else {
                    self.resetRecordingState(
                        completing: generation ?? self.recordingLifecycle.currentGeneration
                    )
                }
                return
            }

            self.segmentURLs.append(outputFileURL)
            self.durationBudget.includeSegment(durationSeconds: segmentDuration)
            let durationLimitReached = self.durationBudget.remainingSeconds <= 0.05

            if shouldResumeAfterFlip && !durationLimitReached {
                self.statusText = "Switching camera"
                self.resumeAfterCameraFlip()
            } else if shouldFinishForSend {
                if let generation {
                    self.finishRecordedSegments(generation: generation)
                } else {
                    self.resetRecordingState()
                }
            } else {
                if let generation {
                    self.finishRecordedSegments(generation: generation)
                } else {
                    self.resetRecordingState()
                }
            }
        }
    }
}

private final class SendableMovieExportSession: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

private struct RecordedMovieSegment {
    var url: URL
    var asset: AVURLAsset
    var duration: CMTime
    var videoTrack: AVAssetTrack
    var audioTrack: AVAssetTrack?
    var renderSize: CGSize
}

private enum CameraRecorderError: LocalizedError {
    case cameraUnavailable
    case cannotAddVideoInput
    case cannotAddMovieOutput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "Camera unavailable on this device"
        case .cannotAddVideoInput:
            return "Camera input could not be added"
        case .cannotAddMovieOutput:
            return "Movie recorder could not be added"
        }
    }
}

private struct VideoHistoryTile: View {
    let message: Message
    let direction: MessageDirection
    let isSelected: Bool
    let onPlay: () -> Void
    @State private var thumbnailImage: UIImage?

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if let thumbnailImage {
                        Image(uiImage: thumbnailImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 128, height: 112)
                            .clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tileFill)
                    }

                    LinearGradient(
                        colors: [.black.opacity(0.12), .black.opacity(0.58)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading) {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)

                        HStack(spacing: 6) {
                            Image(systemName: message.status.systemImage)
                            Text(message.envelope.media.durationSeconds.durationDisplay)
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(9)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(isSelected ? 0.95 : 0), lineWidth: 2)
                }
                .frame(width: 128, height: 112)

                VStack(alignment: .leading, spacing: 3) {
                    Text(direction == .sent ? "You" : "Them")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)

                    HStack(spacing: 5) {
                        Image(systemName: message.status.systemImage)
                        Text(message.createdAt.relativeShortDisplay)
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
                }
                .frame(width: 128, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction == .sent ? "Play sent video" : "Play received video")
        .task(id: message.localThumbnailURL) {
            thumbnailImage = await loadThumbnailImage()
        }
    }

    private var tileFill: LinearGradient {
        let colors: [Color] = [
            Color(red: 0.18, green: 0.20, blue: 0.20),
            Color(red: 0.06, green: 0.07, blue: 0.07)
        ]

        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func loadThumbnailImage() async -> UIImage? {
        guard let thumbnailURL = message.localThumbnailURL,
              let data = try? Data(contentsOf: thumbnailURL) else {
            return nil
        }
        return UIImage(data: data)
    }
}

private struct InlinePlaybackView: View {
    let file: PlaybackTempFile
    let onStarted: () -> Void
    let onEnded: () -> Void
    @State private var player: AVPlayer
    @State private var didNotifyPlaybackStarted = false

    init(
        file: PlaybackTempFile,
        onStarted: @escaping () -> Void,
        onEnded: @escaping () -> Void
    ) {
        self.file = file
        self.onStarted = onStarted
        self.onEnded = onEnded
        _player = State(initialValue: AVPlayer(url: file.url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .background(Color.black)
            .ignoresSafeArea()
            .onAppear {
                player.play()
            }
            .onDisappear {
                player.pause()
            }
            .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                guard PlaybackStartNotification.shouldNotify(
                    for: status,
                    alreadyNotified: didNotifyPlaybackStarted
                ) else {
                    return
                }
                didNotifyPlaybackStarted = true
                onStarted()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem
            )) { _ in
                onEnded()
            }
    }
}

enum PlaybackStartNotification {
    static func shouldNotify(
        for status: AVPlayer.TimeControlStatus,
        alreadyNotified: Bool
    ) -> Bool {
        status == .playing && !alreadyNotified
    }
}

struct ConversationTimelineView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ConversationTimelineView(contact: PreviewData.sample.contacts[0])
        }
        .environmentObject(AppState())
    }
}
