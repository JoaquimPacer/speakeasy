import Foundation
import XCTest
@testable import Kithra

final class MediaPipelineStagingTests: XCTestCase {
    private let ciphertext = Data("verified incoming ciphertext".utf8)
    private let ciphertextHash = Data(hex: "93cd568f197d6a42027ae6e89d458db225c27d43e79007fd0f9fff31f75126d8")

    func testReceivedPackageRemainsStagedUntilExplicitCommit() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root) }

        let message = makeMessage(ciphertextHash: ciphertextHash)
        let staged = try await fixture.pipeline.stageReceivedPackage(
            message: message,
            downloadedBlobURL: fixture.downloadedBlobURL
        )
        let stagedURL = fixture.stagedURL(for: staged.id)
        let durableURL = fixture.durableURL(for: message.id)

        XCTAssertTrue(fixture.fileManager.fileExists(atPath: stagedURL.path))
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: durableURL.path))
        let localPackageBeforeCommit = await fixture.pipeline.localEncryptedPackageURL(
            for: .incomingServerMessage(message.id)
        )
        XCTAssertNil(localPackageBeforeCommit)

        let committed = try await fixture.pipeline.commitStagedReceivedPackage(
            staged,
            allowExistingExactRecovery: false
        )

        XCTAssertFalse(fixture.fileManager.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(committed.localEncryptedCopyURL, durableURL)
        XCTAssertEqual(try Data(contentsOf: durableURL), ciphertext)

        // Discard is scoped to the derived staging path and cannot remove the
        // durable package after promotion.
        await fixture.pipeline.discardStagedReceivedPackage(staged)
        XCTAssertEqual(try Data(contentsOf: durableURL), ciphertext)
    }

    func testCommitCollisionPreservesDurableAndStagedPackages() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root) }

        let message = makeMessage(ciphertextHash: ciphertextHash)
        let staged = try await fixture.pipeline.stageReceivedPackage(
            message: message,
            downloadedBlobURL: fixture.downloadedBlobURL
        )
        let stagedURL = fixture.stagedURL(for: staged.id)
        let durableURL = fixture.durableURL(for: message.id)
        let existingData = Data("existing durable ciphertext".utf8)
        try existingData.write(to: durableURL, options: [.atomic, .completeFileProtection])

        do {
            _ = try await fixture.pipeline.commitStagedReceivedPackage(
                staged,
                allowExistingExactRecovery: false
            )
            XCTFail("Expected an existing durable package to reject promotion")
        } catch MediaPipelineError.localPackageCollision(let messageID) {
            XCTAssertEqual(messageID, message.id)
        }

        XCTAssertEqual(try Data(contentsOf: durableURL), existingData)
        XCTAssertEqual(try Data(contentsOf: stagedURL), ciphertext)

        await fixture.pipeline.discardStagedReceivedPackage(staged)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try Data(contentsOf: durableURL), existingData)
    }

    func testStageValidatesEveryCiphertextHashByteBeforeWriting() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root) }

        var mismatchedHash = ciphertextHash
        mismatchedHash[mismatchedHash.index(before: mismatchedHash.endIndex)] ^= 0x01
        let message = makeMessage(ciphertextHash: mismatchedHash)

        do {
            _ = try await fixture.pipeline.stageReceivedPackage(
                message: message,
                downloadedBlobURL: fixture.downloadedBlobURL
            )
            XCTFail("Expected a mismatch in the final hash byte to be rejected")
        } catch MediaPipelineError.cryptoOperationFailed(_) {
            // Expected.
        }

        let stagingContents = try fixture.fileManager.contentsOfDirectory(
            at: fixture.stagingRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stagingContents.isEmpty)
        let localPackage = await fixture.pipeline.localEncryptedPackageURL(
            for: .incomingServerMessage(message.id)
        )
        XCTAssertNil(localPackage)
    }

    func testCommitRevalidatesStagedCiphertextBeforePromotion() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root) }

        let message = makeMessage(ciphertextHash: ciphertextHash)
        let staged = try await fixture.pipeline.stageReceivedPackage(
            message: message,
            downloadedBlobURL: fixture.downloadedBlobURL
        )
        let stagedURL = fixture.stagedURL(for: staged.id)
        var tamperedCiphertext = ciphertext
        tamperedCiphertext[tamperedCiphertext.index(before: tamperedCiphertext.endIndex)] ^= 0x01
        try tamperedCiphertext.write(to: stagedURL, options: [.atomic, .completeFileProtection])

        do {
            _ = try await fixture.pipeline.commitStagedReceivedPackage(
                staged,
                allowExistingExactRecovery: false
            )
            XCTFail("Expected changed staged ciphertext to be rejected")
        } catch MediaPipelineError.cryptoOperationFailed(_) {
            // Expected.
        }

        XCTAssertFalse(fixture.fileManager.fileExists(atPath: fixture.durableURL(for: message.id).path))
        XCTAssertEqual(try Data(contentsOf: stagedURL), tamperedCiphertext)
        await fixture.pipeline.discardStagedReceivedPackage(staged)
        XCTAssertFalse(fixture.fileManager.fileExists(atPath: stagedURL.path))
    }

    func testOutgoingClientIDCopyCollisionPreservesExistingDurablePackage() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root) }

        let messageID = UUID()
        let sourceURL = fixture.root.appendingPathComponent("outgoing.blob")
        let outgoingData = Data("outgoing ciphertext".utf8)
        try outgoingData.write(to: sourceURL, options: .atomic)

        let firstURL = try await fixture.pipeline.persistOutgoingPackage(
            sourceURL,
            clientMessageID: messageID
        )
        XCTAssertEqual(try Data(contentsOf: firstURL), outgoingData)

        let replacementURL = fixture.root.appendingPathComponent("replacement.blob")
        let replacementData = Data("replacement ciphertext".utf8)
        try replacementData.write(to: replacementURL, options: .atomic)

        do {
            _ = try await fixture.pipeline.persistOutgoingPackage(
                replacementURL,
                clientMessageID: messageID
            )
            XCTFail("Expected an existing outgoing package to reject replacement")
        } catch MediaPipelineError.localPackageCollision(let collidedMessageID) {
            XCTAssertEqual(collidedMessageID, messageID)
        }

        XCTAssertEqual(try Data(contentsOf: firstURL), outgoingData)
    }

    func testOutgoingClientAndIncomingServerIDsUseSeparateDurableNamespaces() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root) }

        let sharedID = UUID()
        let outgoingSourceURL = fixture.root.appendingPathComponent("outgoing-shared-id.blob")
        let outgoingData = Data("outgoing ciphertext with a local client ID".utf8)
        try outgoingData.write(to: outgoingSourceURL, options: .atomic)
        let outgoingURL = try await fixture.pipeline.persistOutgoingPackage(
            outgoingSourceURL,
            clientMessageID: sharedID
        )

        let incomingMessage = makeMessage(
            id: sharedID,
            ciphertextHash: ciphertextHash
        )
        let staged = try await fixture.pipeline.stageReceivedPackage(
            message: incomingMessage,
            downloadedBlobURL: fixture.downloadedBlobURL
        )
        let incomingPackage = try await fixture.pipeline.commitStagedReceivedPackage(
            staged,
            allowExistingExactRecovery: false
        )

        XCTAssertNotEqual(outgoingURL, incomingPackage.localEncryptedCopyURL)
        XCTAssertEqual(try Data(contentsOf: outgoingURL), outgoingData)
        XCTAssertEqual(try Data(contentsOf: incomingPackage.localEncryptedCopyURL), ciphertext)
        let lookedUpOutgoing = await fixture.pipeline.localEncryptedPackageURL(
            for: .outgoingClientMessage(sharedID)
        )
        let lookedUpIncoming = await fixture.pipeline.localEncryptedPackageURL(
            for: .incomingServerMessage(sharedID)
        )
        XCTAssertEqual(lookedUpOutgoing, outgoingURL)
        XCTAssertEqual(lookedUpIncoming, incomingPackage.localEncryptedCopyURL)
    }

    func testThumbnailLookupRequiresDirectionAuthorityAndAuthenticatedSignature() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root) }
        try fixture.fileManager.createDirectory(
            at: fixture.tempRoot,
            withIntermediateDirectories: true
        )

        let authoritativeID = UUID()
        let replayServerID = UUID()
        let signature = Data(repeating: 0x55, count: 64)
        let changedSignature = Data(repeating: 0x56, count: 64)
        let outgoing = try AuthenticatedThumbnailIdentifier(
            authority: .outgoingClientMessage(authoritativeID),
            envelopeSignature: signature
        )
        let incoming = try AuthenticatedThumbnailIdentifier(
            authority: .incomingServerMessage(authoritativeID),
            envelopeSignature: signature
        )
        let incomingReplay = try AuthenticatedThumbnailIdentifier(
            authority: .incomingServerMessage(replayServerID),
            envelopeSignature: signature
        )
        let incomingChanged = try AuthenticatedThumbnailIdentifier(
            authority: .incomingServerMessage(authoritativeID),
            envelopeSignature: changedSignature
        )
        let outgoingURL = fixture.thumbnailURL(
            authority: "outgoing-client-\(authoritativeID.uuidString)",
            signature: signature
        )
        try Data("outgoing thumbnail".utf8).write(to: outgoingURL)

        let lookedUpOutgoing = await fixture.pipeline.localThumbnailURL(for: outgoing)
        let lookedUpIncoming = await fixture.pipeline.localThumbnailURL(for: incoming)
        let lookedUpReplay = await fixture.pipeline.localThumbnailURL(for: incomingReplay)
        let lookedUpChanged = await fixture.pipeline.localThumbnailURL(for: incomingChanged)
        XCTAssertEqual(lookedUpOutgoing, outgoingURL)
        XCTAssertNil(lookedUpIncoming)
        XCTAssertNil(lookedUpReplay)
        XCTAssertNil(lookedUpChanged)
    }

    func testPendingReceiptRecoveryAcceptsOnlyExactExistingCiphertext() async throws {
        let fixture = try makeFixture()
        defer { try? fixture.fileManager.removeItem(at: fixture.root) }

        let message = makeMessage(ciphertextHash: ciphertextHash)
        let firstStage = try await fixture.pipeline.stageReceivedPackage(
            message: message,
            downloadedBlobURL: fixture.downloadedBlobURL
        )
        _ = try await fixture.pipeline.commitStagedReceivedPackage(
            firstStage,
            allowExistingExactRecovery: false
        )

        let recoveryStage = try await fixture.pipeline.stageReceivedPackage(
            message: message,
            downloadedBlobURL: fixture.downloadedBlobURL
        )
        let recovered = try await fixture.pipeline.commitStagedReceivedPackage(
            recoveryStage,
            allowExistingExactRecovery: true
        )
        XCTAssertEqual(recovered.localEncryptedCopyURL, fixture.durableURL(for: message.id))
        XCTAssertFalse(fixture.fileManager.fileExists(
            atPath: fixture.stagedURL(for: recoveryStage.id).path
        ))
        XCTAssertEqual(try Data(contentsOf: recovered.localEncryptedCopyURL), ciphertext)
    }

    private func makeFixture() throws -> PipelineFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("KithraMediaPipelineTests-\(UUID().uuidString)", isDirectory: true)
        let tempRoot = root.appendingPathComponent("Temp", isDirectory: true)
        let localMediaRoot = root.appendingPathComponent("Local", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let downloadedBlobURL = root.appendingPathComponent("downloaded.blob")
        try ciphertext.write(to: downloadedBlobURL, options: .atomic)

        return PipelineFixture(
            fileManager: fileManager,
            root: root,
            tempRoot: tempRoot,
            localMediaRoot: localMediaRoot,
            downloadedBlobURL: downloadedBlobURL,
            pipeline: DefaultMediaPipeline(
                fileManager: fileManager,
                tempRoot: tempRoot,
                localMediaRoot: localMediaRoot
            )
        )
    }

    private func makeMessage(
        id: UUID = UUID(),
        ciphertextHash: Data
    ) -> Message {
        let senderDeviceID = UUID()
        let recipientDeviceID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_785_691_112)
        return Message(
            id: id,
            senderID: UUID(),
            senderDeviceID: senderDeviceID,
            recipientID: UUID(),
            recipientDeviceID: recipientDeviceID,
            envelope: MessageEnvelope(
                version: MessageEnvelope.authenticatedVersion,
                senderDeviceID: senderDeviceID,
                recipientDeviceID: recipientDeviceID,
                media: EncryptedMediaDescriptor(
                    algorithm: EncryptedMediaDescriptor.xChaCha20Poly1305,
                    nonce: Data(repeating: 0x11, count: 24),
                    ciphertextHash: ciphertextHash,
                    mimeType: "video/mp4",
                    durationSeconds: 1,
                    thumbnail: nil
                ),
                contentKey: ContentKeyEnvelope(
                    algorithm: ContentKeyEnvelope.sealedBox,
                    encryptedContentKey: Data(repeating: 0x22, count: 80),
                    recipientPublicKeyFingerprint: nil
                ),
                senderContentKey: nil,
                createdAt: createdAt,
                clientMessageID: UUID(),
                senderIdentityDigest: Data(repeating: 0x33, count: 32),
                recipientIdentityDigest: Data(repeating: 0x44, count: 32),
                authenticationAlgorithm: MessageEnvelope.ed25519Authentication,
                signature: Data(repeating: 0x55, count: 64)
            ),
            encryptedBlobPath: "/messages/test/blob",
            blobSize: ciphertext.count,
            status: .sent,
            deliveredAt: nil,
            blobDeletedAt: nil,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(86_400)
        )
    }
}

private struct PipelineFixture {
    let fileManager: FileManager
    let root: URL
    let tempRoot: URL
    let localMediaRoot: URL
    let downloadedBlobURL: URL
    let pipeline: DefaultMediaPipeline

    var stagingRoot: URL {
        tempRoot.appendingPathComponent("IncomingStaging", isDirectory: true)
    }

    func stagedURL(for stagingID: UUID) -> URL {
        stagingRoot
            .appendingPathComponent("incoming-\(stagingID.uuidString)")
            .appendingPathExtension("blob")
    }

    func durableURL(for messageID: UUID) -> URL {
        localMediaRoot
            .appendingPathComponent("incoming-server-\(messageID.uuidString)")
            .appendingPathExtension("blob")
    }

    func thumbnailURL(authority: String, signature: Data) -> URL {
        tempRoot
            .appendingPathComponent("thumb-\(authority)-auth-\(signature.hexString)")
            .appendingPathExtension("jpg")
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2))
        self.init()
        reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
}
