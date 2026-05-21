import AVFoundation
import Foundation

enum MediaPipelineError: Error, LocalizedError {
    case recordingNotWired
    case exportSessionUnavailable
    case exportFailed
    case exportCancelled
    case libsodiumBindingRequired(String)

    var errorDescription: String? {
        switch self {
        case .recordingNotWired:
            return "The AVFoundation recording session has not been wired yet."
        case .exportSessionUnavailable:
            return "AVFoundation could not create a video export session."
        case .exportFailed:
            return "The video export failed."
        case .exportCancelled:
            return "The video export was cancelled."
        case .libsodiumBindingRequired(let operation):
            return "\(operation) requires the libsodium binding to be installed."
        }
    }
}

enum DeliveryVideoQuality: String, Codable, CaseIterable, Identifiable {
    case compact480p
    case standard720p

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact480p:
            return "480p"
        case .standard720p:
            return "720p"
        }
    }

    var exportPreset: String {
        switch self {
        case .compact480p:
            return AVAssetExportPresetMediumQuality
        case .standard720p:
            return AVAssetExportPreset1280x720
        }
    }
}

struct RawRecordingConfiguration: Hashable {
    var maxDurationSeconds: TimeInterval = 120
    var quality: DeliveryVideoQuality = .compact480p
    var includeAudio: Bool = true
}

struct EncryptedMediaPackage: Identifiable, Hashable {
    let id: UUID
    var messageID: UUID?
    var envelope: MessageEnvelope
    var encryptedBlobURL: URL
    var localEncryptedCopyURL: URL
    var blobSize: Int
}

struct PlaybackTempFile: Identifiable, Hashable {
    let id: UUID
    var url: URL
    var createdAt: Date
    var cleanupDeadline: Date
}

protocol MediaPipelining {
    func makeRawRecordingURL() throws -> URL
    func recordRawTemp(configuration: RawRecordingConfiguration) async throws -> URL
    func compressForDelivery(rawVideoURL: URL, quality: DeliveryVideoQuality) async throws -> URL
    func encryptPackage(
        compressedVideoURL: URL,
        thumbnailURL: URL?,
        recipient: Contact,
        senderDeviceID: UUID,
        recipientDeviceID: UUID
    ) async throws -> EncryptedMediaPackage
    func decryptForPlayback(package: EncryptedMediaPackage) async throws -> PlaybackTempFile
    func cleanupTemporaryFiles(_ urls: [URL]) async
}

final class DefaultMediaPipeline: MediaPipelining {
    private let fileManager: FileManager
    private let tempRoot: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("SpeakeasyMedia", isDirectory: true)
    }

    func makeRawRecordingURL() throws -> URL {
        try ensureTempRoot()
        return tempRoot
            .appendingPathComponent("raw-\(UUID().uuidString)")
            .appendingPathExtension("mov")
    }

    func recordRawTemp(configuration: RawRecordingConfiguration) async throws -> URL {
        _ = configuration
        _ = try makeRawRecordingURL()
        throw MediaPipelineError.recordingNotWired
    }

    func compressForDelivery(rawVideoURL: URL, quality: DeliveryVideoQuality) async throws -> URL {
        try ensureTempRoot()

        let outputURL = tempRoot
            .appendingPathComponent("delivery-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        let asset = AVURLAsset(url: rawVideoURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: quality.exportPreset) else {
            throw MediaPipelineError.exportSessionUnavailable
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        return try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(returning: outputURL)
                case .cancelled:
                    continuation.resume(throwing: MediaPipelineError.exportCancelled)
                case .failed:
                    continuation.resume(throwing: exportSession.error ?? MediaPipelineError.exportFailed)
                default:
                    continuation.resume(throwing: MediaPipelineError.exportFailed)
                }
            }
        }
    }

    func encryptPackage(
        compressedVideoURL: URL,
        thumbnailURL: URL?,
        recipient: Contact,
        senderDeviceID: UUID,
        recipientDeviceID: UUID
    ) async throws -> EncryptedMediaPackage {
        _ = compressedVideoURL
        _ = thumbnailURL
        _ = recipient
        _ = senderDeviceID
        _ = recipientDeviceID
        throw MediaPipelineError.libsodiumBindingRequired(
            "Encrypting video packages with XChaCha20-Poly1305"
        )
    }

    func decryptForPlayback(package: EncryptedMediaPackage) async throws -> PlaybackTempFile {
        _ = package
        throw MediaPipelineError.libsodiumBindingRequired(
            "Decrypting local encrypted packages for temporary playback"
        )
    }

    func cleanupTemporaryFiles(_ urls: [URL]) async {
        for url in urls {
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                assertionFailure("Temporary file cleanup failed for \(url.path): \(error)")
            }
        }
    }

    private func ensureTempRoot() throws {
        if !fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        }
    }
}
