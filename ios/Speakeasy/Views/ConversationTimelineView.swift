@preconcurrency import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct ConversationTimelineView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @StateObject private var recorder = InlineVideoRecorder()
    @State private var inlinePlayback: InlinePlayback?
    @State private var selectedMessageID: UUID?

    let contact: Contact

    private var messages: [Message] {
        appState.messages(for: contact)
    }

    private var messageIDs: [UUID] {
        messages.map(\.id)
    }

    var body: some View {
        ZStack {
            cameraBackdrop

            VStack(spacing: 0) {
                header
                    .padding(.top, 12)
                    .padding(.horizontal, 18)

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
            recorder.onFinishedRecording = { url in
                sendRecordedVideo(url)
            }
            recorder.prepare()
        }
        .onDisappear {
            recorder.stopSession()
            clearInlinePlayback()
        }
        .task(id: contact.id) {
            await appState.refreshQuietly()
        }
    }

    private var cameraBackdrop: some View {
        ZStack {
            if let inlinePlayback {
                InlinePlaybackView(
                    file: inlinePlayback.file,
                    onEnded: {
                        playNextAfterCurrent()
                    }
                )
                    .id(inlinePlayback.id)
                    .ignoresSafeArea()
            } else {
                CameraPreview(session: recorder.session)
                    .ignoresSafeArea()
                    .opacity(recorder.isReady ? 1 : 0)
            }

            if !recorder.isReady, inlinePlayback == nil {
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
                Text(contact.displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

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
        .disabled(!recorder.isReady || appState.isWorking)
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

    private func sendRecordedVideo(_ url: URL) {
        Task {
            await appState.sendVideo(rawVideoURL: url, quality: .compact480p, to: contact)
            await appState.mediaPipeline.cleanupTemporaryFiles([url])
            await appState.refreshQuietly()
        }
    }

    private func play(_ message: Message) {
        Task {
            guard let playbackFile = await appState.preparePlayback(message: message) else {
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
        guard inlinePlayback != nil || selectedMessageID != nil else {
            return
        }

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

private final class InlineVideoRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onFinishedRecording: ((URL) -> Void)?

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
        isDiscardingRecording = isRecording
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
        guard isReady, !movieOutput.isRecording else {
            return
        }

        errorMessage = nil
        isDiscardingRecording = false
        isStoppingForFinalSend = false
        isSwitchingCameraDuringRecording = false
        segmentURLs.removeAll()
        startRecordingSegment()
    }

    private func startRecordingSegment() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        sessionQueue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording else { return }

            self.applyVideoConnectionSettings()
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
            } else {
                self.finishRecordedSegments()
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
                    self.resetRecordingState()
                } else if self.isStoppingForFinalSend {
                    self.finishRecordedSegments()
                } else if self.isRecording {
                    self.startRecordingSegment()
                }
            }
        }
    }

    private func finishRecordedSegments() {
        updateOnMain {
            let segments = self.segmentURLs
            self.segmentURLs.removeAll()
            self.isRecording = false
            self.isStoppingForFinalSend = false
            self.isSwitchingCameraDuringRecording = false
            self.statusText = "Preparing video"

            Task { [weak self] in
                do {
                    let outputURL = try await Self.combineSegments(segments)
                    DispatchQueue.main.async { [weak self] in
                        self?.statusText = "Ready"
                        self?.onFinishedRecording?(outputURL)
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.errorMessage = error.localizedDescription
                        self?.statusText = "Ready"
                    }
                }
            }
        }
    }

    private func resetRecordingState() {
        let cleanupURLs = segmentURLs
        segmentURLs.removeAll()
        isDiscardingRecording = false
        isStoppingForFinalSend = false
        isSwitchingCameraDuringRecording = false
        isRecording = false
        statusText = "Ready"
        for cleanupURL in cleanupURLs {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
    }

    private static func combineSegments(_ segments: [URL]) async throws -> URL {
        guard let firstSegment = segments.first else {
            throw MediaPipelineError.exportFailed
        }
        guard segments.count > 1 else {
            return firstSegment
        }

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

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-merged-\(UUID().uuidString)")
            .appendingPathExtension("mov")
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

        return try await withCheckedThrowingContinuation { continuation in
            exportBox.session.exportAsynchronously {
                switch exportBox.session.status {
                case .completed:
                    for segmentURL in segments {
                        try? FileManager.default.removeItem(at: segmentURL)
                    }
                    continuation.resume(returning: outputURL)
                case .cancelled:
                    continuation.resume(throwing: MediaPipelineError.exportCancelled)
                case .failed:
                    continuation.resume(throwing: exportBox.session.error ?? MediaPipelineError.exportFailed)
                default:
                    continuation.resume(throwing: MediaPipelineError.exportFailed)
                }
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
        updateOnMain {
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
        let shouldDiscard = isDiscardingRecording
        let shouldResumeAfterFlip = isSwitchingCameraDuringRecording && !shouldDiscard
        let shouldFinishForSend = isStoppingForFinalSend && !shouldDiscard
        var recordingError: String?

        if let error {
            let nsError = error as NSError
            let finished = (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if !finished {
                recordingError = error.localizedDescription
            }
        }

        updateOnMain {
            if let recordingError {
                self.errorMessage = recordingError
                if shouldResumeAfterFlip {
                    self.resumeAfterCameraFlip()
                } else {
                    self.resetRecordingState()
                }
                return
            }

            if shouldDiscard {
                self.segmentURLs.append(outputFileURL)
                self.resetRecordingState()
                return
            }

            self.segmentURLs.append(outputFileURL)

            if shouldResumeAfterFlip {
                self.statusText = "Switching camera"
                self.resumeAfterCameraFlip()
            } else if shouldFinishForSend {
                self.finishRecordedSegments()
            } else {
                self.finishRecordedSegments()
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
    let onEnded: () -> Void
    @State private var player: AVPlayer

    init(file: PlaybackTempFile, onEnded: @escaping () -> Void) {
        self.file = file
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
            .onReceive(NotificationCenter.default.publisher(
                for: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem
            )) { _ in
                onEnded()
            }
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
