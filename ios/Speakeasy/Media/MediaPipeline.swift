@preconcurrency import AVFoundation
import Foundation
import Sodium
import UIKit

enum MediaPipelineError: Error, LocalizedError {
    case recordingNotWired
    case exportSessionUnavailable
    case exportFailed
    case exportCancelled
    case cryptoOperationFailed(String)

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
        case .cryptoOperationFailed(let operation):
            return "\(operation) failed."
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
    func makeThumbnail(videoURL: URL, id: UUID) async throws -> URL
    func encryptPackage(
        compressedVideoURL: URL,
        thumbnailURL: URL?,
        recipient: Contact,
        senderDeviceID: UUID,
        recipientDeviceID: UUID
    ) async throws -> EncryptedMediaPackage
    func copyLocalPackage(_ encryptedPackageURL: URL, messageID: UUID) async throws -> URL
    func localEncryptedPackageURL(for messageID: UUID) async -> URL?
    func localThumbnailURL(for messageID: UUID) async -> URL?
    func cacheReceivedPackage(message: Message, downloadedBlobURL: URL) async throws -> EncryptedMediaPackage
    func decryptForPlayback(package: EncryptedMediaPackage) async throws -> PlaybackTempFile
    func cleanupTemporaryFiles(_ urls: [URL]) async
    func removeAllLocalMedia() async
}

final class DefaultMediaPipeline: MediaPipelining {
    private let fileManager: FileManager
    private let keyManager: DeviceKeyManaging
    private let tempRoot: URL
    private let sodium = Sodium()

    init(fileManager: FileManager = .default, keyManager: DeviceKeyManaging = KeychainDeviceKeyManager()) {
        self.fileManager = fileManager
        self.keyManager = keyManager
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
        let exportBox = SendableExportSession(exportSession)

        exportBox.session.outputURL = outputURL
        exportBox.session.outputFileType = .mp4
        exportBox.session.shouldOptimizeForNetworkUse = true

        return try await withCheckedThrowingContinuation { continuation in
            exportBox.session.exportAsynchronously {
                switch exportBox.session.status {
                case .completed:
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

    func makeThumbnail(videoURL: URL, id: UUID) async throws -> URL {
        try ensureTempRoot()

        let asset = AVURLAsset(url: videoURL)
        let duration = CMTimeGetSeconds(asset.duration)
        let captureTime = duration.isFinite && duration > 0.2 ? duration - 0.1 : 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let cgImage = try generator.copyCGImage(
            at: CMTime(seconds: captureTime, preferredTimescale: 600),
            actualTime: nil
        )
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.78) else {
            throw MediaPipelineError.exportFailed
        }

        let outputURL = localThumbnailURLPath(for: id)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try data.write(to: outputURL, options: [.atomic])
        return outputURL
    }

    func encryptPackage(
        compressedVideoURL: URL,
        thumbnailURL: URL?,
        recipient: Contact,
        senderDeviceID: UUID,
        recipientDeviceID: UUID
    ) async throws -> EncryptedMediaPackage {
        try ensureTempRoot()

        let contentKey = sodium.aead.xchacha20poly1305ietf.key()
        let plaintext = try Data(contentsOf: compressedVideoURL)
        guard let encrypted = sodium.aead.xchacha20poly1305ietf.encrypt(
            message: Array(plaintext),
            secretKey: contentKey
        ) as (authenticatedCipherText: Bytes, nonce: Bytes)? else {
            throw MediaPipelineError.cryptoOperationFailed("Encrypting the media package")
        }
        guard let sealedContentKey = sodium.box.seal(
            message: contentKey,
            recipientPublicKey: Array(recipient.encryptionPublicKey)
        ) else {
            throw MediaPipelineError.cryptoOperationFailed("Sealing the media content key")
        }
        guard let ciphertextHash = sodium.genericHash.hash(
            message: encrypted.authenticatedCipherText,
            outputLength: 32
        ) else {
            throw MediaPipelineError.cryptoOperationFailed("Hashing the encrypted media package")
        }
        var senderContentKey: ContentKeyEnvelope?
        if let senderIdentity = try await keyManager.currentIdentity(),
           senderIdentity.deviceID == nil || senderIdentity.deviceID == senderDeviceID {
            senderContentKey = try await keyManager.encryptContentKey(
                Data(contentKey),
                recipientPublicKey: senderIdentity.encryptionPublicKey
            )
        }

        let packageID = UUID()
        let encryptedBlobURL = tempRoot
            .appendingPathComponent("encrypted-\(packageID.uuidString)")
            .appendingPathExtension("blob")
        let localEncryptedCopyURL = tempRoot
            .appendingPathComponent("local-encrypted-\(packageID.uuidString)")
            .appendingPathExtension("blob")
        let encryptedData = Data(encrypted.authenticatedCipherText)

        try encryptedData.write(to: encryptedBlobURL, options: [.atomic])
        if fileManager.fileExists(atPath: localEncryptedCopyURL.path) {
            try fileManager.removeItem(at: localEncryptedCopyURL)
        }
        try fileManager.copyItem(at: encryptedBlobURL, to: localEncryptedCopyURL)

        let durationSeconds = durationSeconds(for: compressedVideoURL)
        let envelope = MessageEnvelope(
            version: 1,
            senderDeviceID: senderDeviceID,
            recipientDeviceID: recipientDeviceID,
            media: EncryptedMediaDescriptor(
                algorithm: EncryptedMediaDescriptor.xChaCha20Poly1305,
                nonce: Data(encrypted.nonce),
                ciphertextHash: Data(ciphertextHash),
                mimeType: "video/mp4",
                durationSeconds: durationSeconds,
                thumbnail: nil
            ),
            contentKey: ContentKeyEnvelope(
                algorithm: ContentKeyEnvelope.sealedBox,
                encryptedContentKey: Data(sealedContentKey),
                recipientPublicKeyFingerprint: Data(recipient.encryptionPublicKey.prefix(16)).base64EncodedString()
            ),
            senderContentKey: senderContentKey,
            createdAt: Date()
        )

        _ = thumbnailURL
        return EncryptedMediaPackage(
            id: packageID,
            messageID: nil,
            envelope: envelope,
            encryptedBlobURL: encryptedBlobURL,
            localEncryptedCopyURL: localEncryptedCopyURL,
            blobSize: encryptedData.count
        )
    }

    func copyLocalPackage(_ encryptedPackageURL: URL, messageID: UUID) async throws -> URL {
        try ensureTempRoot()

        let localURL = localEncryptedPackageURLPath(for: messageID)
        if fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }
        try fileManager.copyItem(at: encryptedPackageURL, to: localURL)
        return localURL
    }

    func localEncryptedPackageURL(for messageID: UUID) async -> URL? {
        let preferredURL = localEncryptedPackageURLPath(for: messageID)
        if fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        let legacyReceivedURL = tempRoot
            .appendingPathComponent("received-\(messageID.uuidString)")
            .appendingPathExtension("blob")
        if fileManager.fileExists(atPath: legacyReceivedURL.path) {
            return legacyReceivedURL
        }

        return nil
    }

    func localThumbnailURL(for messageID: UUID) async -> URL? {
        let url = localThumbnailURLPath(for: messageID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func cacheReceivedPackage(message: Message, downloadedBlobURL: URL) async throws -> EncryptedMediaPackage {
        try ensureTempRoot()

        let encryptedData = try Data(contentsOf: downloadedBlobURL)
        if let expectedHash = message.envelope.media.ciphertextHash {
            guard let actualHash = sodium.genericHash.hash(
                message: Array(encryptedData),
                outputLength: expectedHash.count
            ), Data(actualHash) == expectedHash else {
                throw MediaPipelineError.cryptoOperationFailed("Verifying the downloaded media package")
            }
        }

        let localEncryptedCopyURL = localEncryptedPackageURLPath(for: message.id)
        if fileManager.fileExists(atPath: localEncryptedCopyURL.path) {
            try fileManager.removeItem(at: localEncryptedCopyURL)
        }
        try encryptedData.write(to: localEncryptedCopyURL, options: [.atomic])

        return EncryptedMediaPackage(
            id: message.id,
            messageID: message.id,
            envelope: message.envelope,
            encryptedBlobURL: localEncryptedCopyURL,
            localEncryptedCopyURL: localEncryptedCopyURL,
            blobSize: encryptedData.count
        )
    }

    func decryptForPlayback(package: EncryptedMediaPackage) async throws -> PlaybackTempFile {
        try ensureTempRoot()

        let contentKey = try await keyManager.decryptContentKey(from: package.envelope.contentKey)
        let encryptedURL = fileManager.fileExists(atPath: package.localEncryptedCopyURL.path)
            ? package.localEncryptedCopyURL
            : package.encryptedBlobURL
        let encryptedData = try Data(contentsOf: encryptedURL)

        guard let plaintext = sodium.aead.xchacha20poly1305ietf.decrypt(
            authenticatedCipherText: Array(encryptedData),
            secretKey: Array(contentKey),
            nonce: Array(package.envelope.media.nonce)
        ) else {
            throw MediaPipelineError.cryptoOperationFailed("Decrypting the media package")
        }

        let outputURL = tempRoot
            .appendingPathComponent("playback-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try Data(plaintext).write(to: outputURL, options: [.atomic])

        return PlaybackTempFile(
            id: UUID(),
            url: outputURL,
            createdAt: Date(),
            cleanupDeadline: Date().addingTimeInterval(15 * 60)
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

    func removeAllLocalMedia() async {
        do {
            if fileManager.fileExists(atPath: tempRoot.path) {
                try fileManager.removeItem(at: tempRoot)
            }
        } catch {
            assertionFailure("Local media cleanup failed for \(tempRoot.path): \(error)")
        }
    }

    private func ensureTempRoot() throws {
        if !fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        }
    }

    private func localEncryptedPackageURLPath(for messageID: UUID) -> URL {
        tempRoot
            .appendingPathComponent("local-message-\(messageID.uuidString)")
            .appendingPathExtension("blob")
    }

    private func localThumbnailURLPath(for messageID: UUID) -> URL {
        tempRoot
            .appendingPathComponent("thumb-\(messageID.uuidString)")
            .appendingPathExtension("jpg")
    }

    private func durationSeconds(for videoURL: URL) -> Double? {
        let seconds = CMTimeGetSeconds(AVURLAsset(url: videoURL).duration)
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        return seconds
    }
}

private final class SendableExportSession: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
