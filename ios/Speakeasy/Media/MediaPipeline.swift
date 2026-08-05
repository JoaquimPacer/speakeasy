@preconcurrency import AVFoundation
import Foundation
import Sodium
import UIKit

enum MediaPipelineError: Error, LocalizedError {
    case recordingNotWired
    case exportSessionUnavailable
    case exportFailed
    case exportCancelled
    case stagedPackageMissing
    case localPackageCollision(UUID)
    case invalidAuthenticatedThumbnailIdentifier
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
        case .stagedPackageMissing:
            return "The staged media package is no longer available."
        case .localPackageCollision(let messageID):
            return "An encrypted local package already exists for message \(messageID.uuidString)."
        case .invalidAuthenticatedThumbnailIdentifier:
            return "The local thumbnail identifier is not bound to a valid authenticated envelope signature."
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

/// A hash-validated incoming blob held outside durable message history until
/// the caller has accepted its authenticated replay receipt.
struct StagedReceivedMediaPackage: Identifiable, Hashable {
    let id: UUID
    fileprivate let messageID: UUID
    fileprivate let envelope: MessageEnvelope
}

struct PlaybackTempFile: Identifiable, Hashable {
    let id: UUID
    var url: URL
    var createdAt: Date
    var cleanupDeadline: Date
}

/// Direction-specific storage namespaces keep a relay-selected server ID from
/// addressing an outgoing package that was created and named locally.
enum LocalEncryptedMediaIdentifier: Hashable {
    case outgoingClientMessage(UUID)
    case incomingServerMessage(UUID)
}

/// A thumbnail is addressed by its complete authenticated envelope signature,
/// not by a relay-selected server ID. The direction prefix also prevents an
/// incoming relay record from aliasing locally generated outgoing UI state.
struct AuthenticatedThumbnailIdentifier: Hashable {
    enum Authority: Hashable {
        case outgoingClientMessage(UUID)
        case incomingServerMessage(UUID)
    }

    let authority: Authority
    fileprivate let envelopeSignature: Data

    init(authority: Authority, envelopeSignature: Data) throws {
        guard envelopeSignature.count == 64 else {
            throw MediaPipelineError.invalidAuthenticatedThumbnailIdentifier
        }
        self.authority = authority
        self.envelopeSignature = envelopeSignature
    }
}

protocol MediaPipelining {
    func makeRawRecordingURL() throws -> URL
    func recordRawTemp(configuration: RawRecordingConfiguration) async throws -> URL
    func compressForDelivery(rawVideoURL: URL, quality: DeliveryVideoQuality) async throws -> URL
    func makeThumbnail(
        videoURL: URL,
        identifier: AuthenticatedThumbnailIdentifier
    ) async throws -> URL
    func encryptPackage(
        compressedVideoURL: URL,
        thumbnailURL: URL?,
        recipientEncryptionPublicKey: Data,
        senderUserID: UUID,
        senderDeviceID: UUID,
        senderIdentityDigest: Data,
        recipientUserID: UUID,
        recipientDeviceID: UUID,
        recipientIdentityDigest: Data
    ) async throws -> EncryptedMediaPackage
    func persistOutgoingPackage(
        _ encryptedPackageURL: URL,
        clientMessageID: UUID
    ) async throws -> URL
    func localEncryptedPackageURL(for identifier: LocalEncryptedMediaIdentifier) async -> URL?
    func localThumbnailURL(for identifier: AuthenticatedThumbnailIdentifier) async -> URL?
    func stageReceivedPackage(
        message: Message,
        downloadedBlobURL: URL
    ) async throws -> StagedReceivedMediaPackage
    /// Promotes a stage without replacing durable history. Call only after
    /// the authenticated replay receipt has been accepted.
    func commitStagedReceivedPackage(
        _ stagedPackage: StagedReceivedMediaPackage,
        allowExistingExactRecovery: Bool
    ) async throws -> EncryptedMediaPackage
    /// Removes only the stage derived from this opaque staging token.
    func discardStagedReceivedPackage(_ stagedPackage: StagedReceivedMediaPackage) async
    func validateEncryptedPackage(_ package: EncryptedMediaPackage) async throws
    func decryptForPlayback(package: EncryptedMediaPackage) async throws -> PlaybackTempFile
    func cleanupTemporaryFiles(_ urls: [URL]) async
    func removeAllLocalMedia() async
}

final class DefaultMediaPipeline: MediaPipelining {
    private let fileManager: FileManager
    private let keyManager: DeviceKeyManaging
    private let tempRoot: URL
    private let localMediaRoot: URL
    private let incomingStagingRoot: URL
    private let sodium = Sodium()
    private let messageAuthenticator = MessageEnvelopeAuthenticator()

    init(
        fileManager: FileManager = .default,
        keyManager: DeviceKeyManaging = KeychainDeviceKeyManager(),
        tempRoot: URL? = nil,
        localMediaRoot: URL? = nil
    ) {
        self.fileManager = fileManager
        self.keyManager = keyManager
        let resolvedTempRoot = tempRoot ?? fileManager.temporaryDirectory
            .appendingPathComponent("SpeakeasyMedia", isDirectory: true)
        let resolvedLocalMediaRoot = localMediaRoot
            ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory)
                .appendingPathComponent("KithraMedia", isDirectory: true)
        self.tempRoot = resolvedTempRoot
        self.localMediaRoot = resolvedLocalMediaRoot
        self.incomingStagingRoot = resolvedTempRoot
            .appendingPathComponent("IncomingStaging", isDirectory: true)
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
                    do {
                        try self.fileManager.setAttributes(
                            [.protectionKey: FileProtectionType.complete],
                            ofItemAtPath: outputURL.path
                        )
                        continuation.resume(returning: outputURL)
                    } catch {
                        if self.fileManager.fileExists(atPath: outputURL.path) {
                            try? self.fileManager.removeItem(at: outputURL)
                        }
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if self.fileManager.fileExists(atPath: outputURL.path) {
                        try? self.fileManager.removeItem(at: outputURL)
                    }
                    continuation.resume(throwing: MediaPipelineError.exportCancelled)
                case .failed:
                    if self.fileManager.fileExists(atPath: outputURL.path) {
                        try? self.fileManager.removeItem(at: outputURL)
                    }
                    continuation.resume(throwing: exportBox.session.error ?? MediaPipelineError.exportFailed)
                default:
                    if self.fileManager.fileExists(atPath: outputURL.path) {
                        try? self.fileManager.removeItem(at: outputURL)
                    }
                    continuation.resume(throwing: MediaPipelineError.exportFailed)
                }
            }
        }
    }

    func makeThumbnail(
        videoURL: URL,
        identifier: AuthenticatedThumbnailIdentifier
    ) async throws -> URL {
        try ensureTempRoot()

        let outputURL = localThumbnailURLPath(for: identifier)
        if fileManager.fileExists(atPath: outputURL.path) {
            return outputURL
        }

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

        let stagedURL = tempRoot
            .appendingPathComponent("thumbnail-staged-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        do {
            try data.write(to: stagedURL, options: [.atomic])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: stagedURL.path
            )
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }

        do {
            // Never replace a thumbnail already bound to this authenticated
            // signature. A concurrent writer may win, but relay-selected IDs
            // cannot select or overwrite this path.
            try fileManager.moveItem(at: stagedURL, to: outputURL)
        } catch {
            if fileManager.fileExists(atPath: outputURL.path) {
                try? fileManager.removeItem(at: stagedURL)
                return outputURL
            }
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
        return outputURL
    }

    func encryptPackage(
        compressedVideoURL: URL,
        thumbnailURL: URL?,
        recipientEncryptionPublicKey: Data,
        senderUserID: UUID,
        senderDeviceID: UUID,
        senderIdentityDigest: Data,
        recipientUserID: UUID,
        recipientDeviceID: UUID,
        recipientIdentityDigest: Data
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
            recipientPublicKey: Array(recipientEncryptionPublicKey)
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
        let createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let unsignedEnvelope = MessageEnvelope(
            version: MessageEnvelope.authenticatedVersion,
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
                recipientPublicKeyFingerprint: nil
            ),
            senderContentKey: senderContentKey,
            createdAt: createdAt,
            clientMessageID: packageID,
            senderIdentityDigest: senderIdentityDigest,
            recipientIdentityDigest: recipientIdentityDigest,
            authenticationAlgorithm: MessageEnvelope.ed25519Authentication,
            signature: nil
        )
        let envelope = try await messageAuthenticator.authenticate(
            envelope: unsignedEnvelope,
            senderUserID: senderUserID,
            recipientUserID: recipientUserID,
            keyManager: keyManager
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

    func persistOutgoingPackage(
        _ encryptedPackageURL: URL,
        clientMessageID: UUID
    ) async throws -> URL {
        try ensureTempRoot()

        let localURL = localEncryptedPackageURLPath(
            for: .outgoingClientMessage(clientMessageID)
        )
        guard !fileManager.fileExists(atPath: localURL.path) else {
            throw MediaPipelineError.localPackageCollision(clientMessageID)
        }
        do {
            // This identifier was generated locally and is covered by the
            // envelope signature before any relay request begins.
            try fileManager.copyItem(at: encryptedPackageURL, to: localURL)
        } catch {
            if fileManager.fileExists(atPath: localURL.path) {
                throw MediaPipelineError.localPackageCollision(clientMessageID)
            }
            throw error
        }
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: localURL.path
            )
        } catch {
            try? fileManager.removeItem(at: localURL)
            throw error
        }
        return localURL
    }

    func localEncryptedPackageURL(for identifier: LocalEncryptedMediaIdentifier) async -> URL? {
        let preferredURL = localEncryptedPackageURLPath(for: identifier)
        if fileManager.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        // Only incoming server IDs can address the pre-release receive-cache
        // layout. Outgoing history never falls back from a signed client ID to
        // a relay-selected namespace.
        if case .incomingServerMessage(let messageID) = identifier {
            let legacyLocalURL = localMediaRoot
                .appendingPathComponent("local-message-\(messageID.uuidString)")
                .appendingPathExtension("blob")
            if fileManager.fileExists(atPath: legacyLocalURL.path) {
                return legacyLocalURL
            }

            let legacyReceivedURL = tempRoot
                .appendingPathComponent("received-\(messageID.uuidString)")
                .appendingPathExtension("blob")
            if fileManager.fileExists(atPath: legacyReceivedURL.path) {
                return legacyReceivedURL
            }
        }

        return nil
    }

    func localThumbnailURL(for identifier: AuthenticatedThumbnailIdentifier) async -> URL? {
        let url = localThumbnailURLPath(for: identifier)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func stageReceivedPackage(
        message: Message,
        downloadedBlobURL: URL
    ) async throws -> StagedReceivedMediaPackage {
        try ensureTempRoot()

        let encryptedData = try Data(contentsOf: downloadedBlobURL)
        try validateCiphertext(
            encryptedData,
            envelope: message.envelope,
            operation: "Verifying the downloaded media package"
        )

        let stagingID = UUID()
        let stagedBlobURL = stagedReceivedPackageURLPath(for: stagingID)
        try encryptedData.write(to: stagedBlobURL, options: [.atomic, .completeFileProtection])

        return StagedReceivedMediaPackage(
            id: stagingID,
            messageID: message.id,
            envelope: message.envelope
        )
    }

    func commitStagedReceivedPackage(
        _ stagedPackage: StagedReceivedMediaPackage,
        allowExistingExactRecovery: Bool
    ) async throws -> EncryptedMediaPackage {
        try ensureTempRoot()

        let stagedBlobURL = stagedReceivedPackageURLPath(for: stagedPackage.id)
        guard fileManager.fileExists(atPath: stagedBlobURL.path) else {
            throw MediaPipelineError.stagedPackageMissing
        }

        let encryptedData = try Data(contentsOf: stagedBlobURL)
        try validateCiphertext(
            encryptedData,
            envelope: stagedPackage.envelope,
            operation: "Verifying the staged media package"
        )

        let localEncryptedCopyURL = localEncryptedPackageURLPath(
            for: .incomingServerMessage(stagedPackage.messageID)
        )
        if fileManager.fileExists(atPath: localEncryptedCopyURL.path) {
            return try recoverExistingPackage(
                stagedPackage: stagedPackage,
                stagedBlobURL: stagedBlobURL,
                stagedData: encryptedData,
                localEncryptedCopyURL: localEncryptedCopyURL,
                allowExistingExactRecovery: allowExistingExactRecovery
            )
        }

        do {
            // FileManager's move has no replace-existing mode. A concurrent
            // writer therefore wins without either package being deleted.
            try fileManager.moveItem(at: stagedBlobURL, to: localEncryptedCopyURL)
        } catch {
            if fileManager.fileExists(atPath: localEncryptedCopyURL.path) {
                return try recoverExistingPackage(
                    stagedPackage: stagedPackage,
                    stagedBlobURL: stagedBlobURL,
                    stagedData: encryptedData,
                    localEncryptedCopyURL: localEncryptedCopyURL,
                    allowExistingExactRecovery: allowExistingExactRecovery
                )
            }
            throw error
        }

        return EncryptedMediaPackage(
            id: stagedPackage.messageID,
            messageID: stagedPackage.messageID,
            envelope: stagedPackage.envelope,
            encryptedBlobURL: localEncryptedCopyURL,
            localEncryptedCopyURL: localEncryptedCopyURL,
            blobSize: encryptedData.count
        )
    }

    private func recoverExistingPackage(
        stagedPackage: StagedReceivedMediaPackage,
        stagedBlobURL: URL,
        stagedData: Data,
        localEncryptedCopyURL: URL,
        allowExistingExactRecovery: Bool
    ) throws -> EncryptedMediaPackage {
        guard allowExistingExactRecovery else {
            throw MediaPipelineError.localPackageCollision(stagedPackage.messageID)
        }

        let existingData = try Data(contentsOf: localEncryptedCopyURL)
        try validateCiphertext(
            existingData,
            envelope: stagedPackage.envelope,
            operation: "Verifying the recovered local media package"
        )
        guard existingData == stagedData else {
            throw MediaPipelineError.localPackageCollision(stagedPackage.messageID)
        }
        if fileManager.fileExists(atPath: stagedBlobURL.path) {
            try fileManager.removeItem(at: stagedBlobURL)
        }

        return EncryptedMediaPackage(
            id: stagedPackage.messageID,
            messageID: stagedPackage.messageID,
            envelope: stagedPackage.envelope,
            encryptedBlobURL: localEncryptedCopyURL,
            localEncryptedCopyURL: localEncryptedCopyURL,
            blobSize: existingData.count
        )
    }

    func discardStagedReceivedPackage(_ stagedPackage: StagedReceivedMediaPackage) async {
        let stagedBlobURL = stagedReceivedPackageURLPath(for: stagedPackage.id)
        do {
            if fileManager.fileExists(atPath: stagedBlobURL.path) {
                try fileManager.removeItem(at: stagedBlobURL)
            }
        } catch {
            assertionFailure("Staged media cleanup failed for \(stagedBlobURL.path): \(error)")
        }
    }

    func validateEncryptedPackage(_ package: EncryptedMediaPackage) async throws {
        let encryptedURL = fileManager.fileExists(atPath: package.localEncryptedCopyURL.path)
            ? package.localEncryptedCopyURL
            : package.encryptedBlobURL
        let encryptedData = try Data(contentsOf: encryptedURL)
        try validateCiphertext(
            encryptedData,
            envelope: package.envelope,
            operation: "Verifying the signed media package"
        )
    }

    func decryptForPlayback(package: EncryptedMediaPackage) async throws -> PlaybackTempFile {
        try ensureTempRoot()

        let encryptedURL = fileManager.fileExists(atPath: package.localEncryptedCopyURL.path)
            ? package.localEncryptedCopyURL
            : package.encryptedBlobURL
        let encryptedData = try Data(contentsOf: encryptedURL)
        try validateCiphertext(
            encryptedData,
            envelope: package.envelope,
            operation: "Verifying the signed media package"
        )

        let contentKey = try await keyManager.decryptContentKey(from: package.envelope.contentKey)

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
        do {
            try Data(plaintext).write(to: outputURL, options: [.atomic])
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: outputURL.path
            )
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }

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
            if fileManager.fileExists(atPath: localMediaRoot.path) {
                try fileManager.removeItem(at: localMediaRoot)
            }
        } catch {
            assertionFailure("Local media cleanup failed: \(error)")
        }
    }

    private func ensureTempRoot() throws {
        if !fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        }
        if !fileManager.fileExists(atPath: incomingStagingRoot.path) {
            try fileManager.createDirectory(
                at: incomingStagingRoot,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        if !fileManager.fileExists(atPath: localMediaRoot.path) {
            try fileManager.createDirectory(
                at: localMediaRoot,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableLocalMediaRoot = localMediaRoot
            try? mutableLocalMediaRoot.setResourceValues(values)
        }
    }

    private func localEncryptedPackageURLPath(
        for identifier: LocalEncryptedMediaIdentifier
    ) -> URL {
        let component: String
        switch identifier {
        case .outgoingClientMessage(let clientMessageID):
            component = "outgoing-client-\(clientMessageID.uuidString)"
        case .incomingServerMessage(let serverMessageID):
            component = "incoming-server-\(serverMessageID.uuidString)"
        }
        return localMediaRoot
            .appendingPathComponent(component)
            .appendingPathExtension("blob")
    }

    private func localThumbnailURLPath(
        for identifier: AuthenticatedThumbnailIdentifier
    ) -> URL {
        // Thumbnails reveal video content, so keep them with short-lived
        // plaintext artifacts rather than persistent encrypted history.
        let authorityComponent: String
        switch identifier.authority {
        case .outgoingClientMessage(let clientMessageID):
            authorityComponent = "outgoing-client-\(clientMessageID.uuidString)"
        case .incomingServerMessage(let serverMessageID):
            authorityComponent = "incoming-server-\(serverMessageID.uuidString)"
        }
        let signatureHex = identifier.envelopeSignature
            .map { String(format: "%02x", $0) }
            .joined()
        return tempRoot
            .appendingPathComponent("thumb-\(authorityComponent)-auth-\(signatureHex)")
            .appendingPathExtension("jpg")
    }

    private func stagedReceivedPackageURLPath(for stagingID: UUID) -> URL {
        incomingStagingRoot
            .appendingPathComponent("incoming-\(stagingID.uuidString)")
            .appendingPathExtension("blob")
    }

    private func validateCiphertext(
        _ encryptedData: Data,
        envelope: MessageEnvelope,
        operation: String
    ) throws {
        guard let expectedHash = envelope.media.ciphertextHash,
              expectedHash.count == 32,
              let actualHash = sodium.genericHash.hash(
                  message: Array(encryptedData),
                  outputLength: 32
              ),
              sodium.utils.equals(actualHash, Array(expectedHash)) else {
            throw MediaPipelineError.cryptoOperationFailed(operation)
        }
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
