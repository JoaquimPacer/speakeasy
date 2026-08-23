import Foundation
import Sodium

enum MessageEnvelopeAuthenticationError: Error, LocalizedError {
    case unsupportedVersion
    case missingField(String)
    case invalidField(String)
    case unexpectedSender
    case unexpectedRecipient
    case unexpectedRelationship
    case identityChanged
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "This message does not use Kithra's authenticated envelope format."
        case .missingField(let field):
            return "The authenticated message is missing \(field)."
        case .invalidField(let field):
            return "The authenticated message has an invalid \(field)."
        case .unexpectedSender:
            return "The message sender does not match the verified contact."
        case .unexpectedRecipient:
            return "The message was not authenticated for this device."
        case .unexpectedRelationship:
            return "The message is not exactly incoming to or outgoing from this device."
        case .identityChanged:
            return "The message identity does not match the verified safety number."
        case .invalidSignature:
            return "The message signature is invalid. Do not trust or play this video."
        }
    }
}

enum AuthenticatedMessageRelationship: Equatable {
    case incoming
    case outgoing
}

struct MessageRelationshipResolver {
    static func resolve(
        message: Message,
        localUserID: UUID,
        localDeviceID: UUID
    ) throws -> AuthenticatedMessageRelationship {
        let isIncoming = message.recipientID == localUserID &&
            message.recipientDeviceID == localDeviceID
        let isOutgoing = message.senderID == localUserID &&
            message.senderDeviceID == localDeviceID

        guard isIncoming != isOutgoing else {
            throw MessageEnvelopeAuthenticationError.unexpectedRelationship
        }
        return isIncoming ? .incoming : .outgoing
    }
}

struct MessageEnvelopeAuthenticator {
    static let domain = Data("KITHRA-MESSAGE-AUTH-v2\0".utf8)

    private let sodium = Sodium()

    func authenticate(
        envelope: MessageEnvelope,
        senderUserID: UUID,
        recipientUserID: UUID,
        keyManager: DeviceKeyManaging
    ) async throws -> MessageEnvelope {
        var authenticatedEnvelope = envelope
        authenticatedEnvelope.signature = nil
        let transcript = try makeTranscript(
            envelope: authenticatedEnvelope,
            senderUserID: senderUserID,
            recipientUserID: recipientUserID
        )
        authenticatedEnvelope.signature = try await keyManager.signMessageAuthenticationTranscript(transcript)
        return authenticatedEnvelope
    }

    func verify(
        message: Message,
        expectedSenderUserID: UUID,
        expectedSenderDeviceID: UUID,
        expectedSenderIdentityDigest: Data,
        expectedSenderSigningPublicKey: Data,
        expectedRecipientUserID: UUID,
        expectedRecipientDeviceID: UUID,
        expectedRecipientIdentityDigest: Data
    ) throws {
        guard message.senderID == expectedSenderUserID,
              message.senderDeviceID == expectedSenderDeviceID,
              message.envelope.senderDeviceID == expectedSenderDeviceID else {
            throw MessageEnvelopeAuthenticationError.unexpectedSender
        }
        guard message.recipientID == expectedRecipientUserID,
              message.recipientDeviceID == expectedRecipientDeviceID,
              message.envelope.recipientDeviceID == expectedRecipientDeviceID else {
            throw MessageEnvelopeAuthenticationError.unexpectedRecipient
        }
        guard let senderDigest = message.envelope.senderIdentityDigest,
              let recipientDigest = message.envelope.recipientIdentityDigest,
              sodium.utils.equals(Array(senderDigest), Array(expectedSenderIdentityDigest)),
              sodium.utils.equals(Array(recipientDigest), Array(expectedRecipientIdentityDigest)) else {
            throw MessageEnvelopeAuthenticationError.identityChanged
        }
        guard expectedSenderSigningPublicKey.count == sodium.sign.PublicKeyBytes else {
            throw MessageEnvelopeAuthenticationError.invalidField("sender signing public key")
        }
        guard let signature = message.envelope.signature else {
            throw MessageEnvelopeAuthenticationError.missingField("signature")
        }
        guard signature.count == sodium.sign.Bytes else {
            throw MessageEnvelopeAuthenticationError.invalidField("signature")
        }

        var unsignedEnvelope = message.envelope
        unsignedEnvelope.signature = nil
        let transcript = try makeTranscript(
            envelope: unsignedEnvelope,
            senderUserID: message.senderID,
            recipientUserID: message.recipientID
        )
        guard sodium.sign.verify(
            message: Array(transcript),
            publicKey: Array(expectedSenderSigningPublicKey),
            signature: Array(signature)
        ) else {
            throw MessageEnvelopeAuthenticationError.invalidSignature
        }
    }

    func makeTranscript(
        envelope: MessageEnvelope,
        senderUserID: UUID,
        recipientUserID: UUID
    ) throws -> Data {
        guard envelope.version == MessageEnvelope.authenticatedVersion else {
            throw MessageEnvelopeAuthenticationError.unsupportedVersion
        }
        guard let clientMessageID = envelope.clientMessageID else {
            throw MessageEnvelopeAuthenticationError.missingField("client message ID")
        }
        guard clientMessageID != Self.zeroUUID,
              senderUserID != Self.zeroUUID,
              envelope.senderDeviceID != Self.zeroUUID,
              recipientUserID != Self.zeroUUID,
              envelope.recipientDeviceID != Self.zeroUUID else {
            throw MessageEnvelopeAuthenticationError.invalidField("UUID")
        }
        guard let senderIdentityDigest = envelope.senderIdentityDigest,
              senderIdentityDigest.count == 32 else {
            throw MessageEnvelopeAuthenticationError.invalidField("sender identity digest")
        }
        guard let recipientIdentityDigest = envelope.recipientIdentityDigest,
              recipientIdentityDigest.count == 32 else {
            throw MessageEnvelopeAuthenticationError.invalidField("recipient identity digest")
        }
        guard envelope.authenticationAlgorithm == MessageEnvelope.ed25519Authentication else {
            throw MessageEnvelopeAuthenticationError.invalidField("authentication algorithm")
        }
        guard let ciphertextHash = envelope.media.ciphertextHash,
              ciphertextHash.count == 32 else {
            throw MessageEnvelopeAuthenticationError.invalidField("ciphertext hash")
        }
        guard envelope.media.algorithm == EncryptedMediaDescriptor.xChaCha20Poly1305 else {
            throw MessageEnvelopeAuthenticationError.invalidField("media algorithm")
        }
        guard envelope.media.nonce.count == 24 else {
            throw MessageEnvelopeAuthenticationError.invalidField("media nonce")
        }
        try validateWireString(
            envelope.media.mimeType,
            name: "media MIME type",
            maximumUTF8ByteCount: 255
        )
        try validateContentKey(envelope.contentKey, name: "recipient content key")
        if let senderContentKey = envelope.senderContentKey {
            try validateContentKey(senderContentKey, name: "sender content key")
        }
        if let thumbnail = envelope.media.thumbnail {
            guard thumbnail.algorithm == EncryptedMediaDescriptor.xChaCha20Poly1305 else {
                throw MessageEnvelopeAuthenticationError.invalidField("thumbnail algorithm")
            }
            guard thumbnail.nonce.count == 24 else {
                throw MessageEnvelopeAuthenticationError.invalidField("thumbnail nonce")
            }
            guard let path = thumbnail.encryptedBlobPath else {
                throw MessageEnvelopeAuthenticationError.missingField("thumbnail encrypted blob path")
            }
            try validateWireString(
                path,
                name: "thumbnail encrypted blob path",
                maximumUTF8ByteCount: 2_048
            )
            guard let hash = thumbnail.ciphertextHash, hash.count == 32 else {
                throw MessageEnvelopeAuthenticationError.invalidField("thumbnail ciphertext hash")
            }
        }
        guard envelope.createdAt.timeIntervalSince1970.rounded(.towardZero) ==
                envelope.createdAt.timeIntervalSince1970 else {
            throw MessageEnvelopeAuthenticationError.invalidField("creation timestamp")
        }

        var writer = CanonicalMessageWriter()
        writer.appendRaw(Self.domain)
        writer.appendUInt16(UInt16(MessageEnvelope.authenticatedVersion))
        writer.appendUUID(clientMessageID)
        writer.appendUUID(senderUserID)
        writer.appendUUID(envelope.senderDeviceID)
        try writer.appendFixed(senderIdentityDigest, count: 32, name: "sender identity digest")
        writer.appendUUID(recipientUserID)
        writer.appendUUID(envelope.recipientDeviceID)
        try writer.appendFixed(recipientIdentityDigest, count: 32, name: "recipient identity digest")
        try writer.appendString(MessageEnvelope.ed25519Authentication)
        try writer.appendString(envelope.media.algorithm)
        try writer.appendData(envelope.media.nonce)
        try writer.appendOptionalData(ciphertextHash)
        try writer.appendString(envelope.media.mimeType)
        try writer.appendOptionalDurationMilliseconds(envelope.media.durationSeconds)
        try writer.appendThumbnail(envelope.media.thumbnail)
        try writer.appendContentKey(envelope.contentKey)
        try writer.appendOptionalContentKey(envelope.senderContentKey)
        try writer.appendDateMilliseconds(envelope.createdAt)
        return writer.data
    }

    private func validateContentKey(_ envelope: ContentKeyEnvelope, name: String) throws {
        guard envelope.algorithm == ContentKeyEnvelope.sealedBox else {
            throw MessageEnvelopeAuthenticationError.invalidField("\(name) algorithm")
        }
        // A libsodium sealed box has 48 bytes of overhead around the 32-byte
        // XChaCha20-Poly1305 content key.
        guard envelope.encryptedContentKey.count == 80 else {
            throw MessageEnvelopeAuthenticationError.invalidField("\(name) length")
        }
        if let fingerprint = envelope.recipientPublicKeyFingerprint {
            try validateWireString(
                fingerprint,
                name: "\(name) recipient public-key fingerprint",
                maximumUTF8ByteCount: 256
            )
        }
    }

    private func validateWireString(
        _ value: String,
        name: String,
        maximumUTF8ByteCount: Int
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8ByteCount,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw MessageEnvelopeAuthenticationError.invalidField(name)
        }
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

private struct CanonicalMessageWriter {
    private(set) var data = Data()

    mutating func appendRaw(_ value: Data) {
        data.append(value)
    }

    mutating func appendUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        appendInteger(value.bigEndian)
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendInteger(value.bigEndian)
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendInteger(value.bigEndian)
    }

    mutating func appendUUID(_ value: UUID) {
        var uuid = value.uuid
        withUnsafeBytes(of: &uuid) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    mutating func appendFixed(_ value: Data, count: Int, name: String) throws {
        guard value.count == count else {
            throw MessageEnvelopeAuthenticationError.invalidField(name)
        }
        data.append(value)
    }

    mutating func appendData(_ value: Data) throws {
        guard value.count <= Int(UInt32.max) else {
            throw MessageEnvelopeAuthenticationError.invalidField("binary field length")
        }
        appendUInt32(UInt32(value.count))
        data.append(value)
    }

    mutating func appendString(_ value: String) throws {
        try appendData(Data(value.utf8))
    }

    mutating func appendOptionalData(_ value: Data?) throws {
        guard let value else {
            appendUInt8(0)
            return
        }
        appendUInt8(1)
        try appendData(value)
    }

    mutating func appendOptionalString(_ value: String?) throws {
        guard let value else {
            appendUInt8(0)
            return
        }
        appendUInt8(1)
        try appendString(value)
    }

    mutating func appendOptionalDurationMilliseconds(_ seconds: Double?) throws {
        guard let seconds else {
            appendUInt8(0)
            return
        }
        let milliseconds = floor(seconds * 1_000 + 0.5)
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(UInt64.max) else {
            throw MessageEnvelopeAuthenticationError.invalidField("media duration")
        }
        appendUInt8(1)
        appendUInt64(UInt64(milliseconds))
    }

    mutating func appendThumbnail(_ thumbnail: EncryptedThumbnailEnvelope?) throws {
        guard let thumbnail else {
            appendUInt8(0)
            return
        }
        appendUInt8(1)
        try appendString(thumbnail.algorithm)
        try appendData(thumbnail.nonce)
        try appendOptionalString(thumbnail.encryptedBlobPath)
        try appendOptionalData(thumbnail.ciphertextHash)
    }

    mutating func appendContentKey(_ envelope: ContentKeyEnvelope) throws {
        try appendString(envelope.algorithm)
        try appendData(envelope.encryptedContentKey)
        try appendOptionalString(envelope.recipientPublicKeyFingerprint)
    }

    mutating func appendOptionalContentKey(_ envelope: ContentKeyEnvelope?) throws {
        guard let envelope else {
            appendUInt8(0)
            return
        }
        appendUInt8(1)
        try appendContentKey(envelope)
    }

    mutating func appendDateMilliseconds(_ date: Date) throws {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds < Double(Int64.max) else {
            throw MessageEnvelopeAuthenticationError.invalidField("creation timestamp")
        }
        appendUInt64(UInt64(bitPattern: Int64(milliseconds)))
    }

    private mutating func appendInteger<T>(_ value: T) {
        var value = value
        withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
