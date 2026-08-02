import Foundation

struct SpeakeasyUser: Identifiable, Codable, Hashable {
    let id: UUID
    var username: String
    var createdAt: Date
}

struct SpeakeasyDevice: Identifiable, Codable, Hashable {
    let id: UUID
    var userID: UUID
    var name: String?
    var encryptionPublicKey: Data
    var signingPublicKey: Data
    var createdAt: Date
    var lastSeenAt: Date?
}

struct DevicePublicIdentity: Codable, Hashable {
    var deviceID: UUID?
    var encryptionPublicKey: Data
    var signingPublicKey: Data
    var createdAt: Date
}

struct Contact: Identifiable, Codable, Hashable {
    var id: UUID { contactID }

    var userID: UUID
    var contactID: UUID
    var deviceID: UUID
    var username: String
    var nickname: String?
    var encryptionPublicKey: Data
    var signingPublicKey: Data
    var createdAt: Date

    var displayName: String {
        if let nickname, !nickname.isEmpty {
            return nickname
        }

        return username
    }
}

enum MessageStatus: String, Codable, CaseIterable, Hashable {
    case sent
    case delivered
    case watched
    case expired
}

enum MessageDirection: String, Codable, Hashable {
    case sent
    case received
}

struct Message: Identifiable, Codable, Hashable {
    let id: UUID
    var senderID: UUID
    var senderDeviceID: UUID?
    var recipientID: UUID
    var recipientDeviceID: UUID?
    var envelope: MessageEnvelope
    var encryptedBlobPath: String?
    // These URLs are local runtime state, never relay wire fields. Keeping a
    // default preserves the memberwise initializer while the custom Codable
    // implementation below deliberately excludes them.
    var localEncryptedPackageURL: URL? = nil
    var localThumbnailURL: URL? = nil
    var blobSize: Int
    var status: MessageStatus
    var deliveredAt: Date?
    var blobDeletedAt: Date?
    var createdAt: Date
    var expiresAt: Date

    func direction(for currentUserID: UUID?) -> MessageDirection {
        guard let currentUserID else {
            return .received
        }

        return senderID == currentUserID ? MessageDirection.sent : MessageDirection.received
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case senderID
        case senderDeviceID
        case recipientID
        case recipientDeviceID
        case envelope
        case encryptedBlobPath
        case blobSize
        case status
        case deliveredAt
        case blobDeletedAt
        case createdAt
        case expiresAt
    }
}

extension Message {
    init(from decoder: Decoder) throws {
        // In particular, reject localEncryptedPackageURL and localThumbnailURL.
        // Accepting either from an untrusted relay would turn a server response
        // into a local-file or network URL read.
        try decoder.rejectUnknownKeys(allowing: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        senderID = try container.decode(UUID.self, forKey: .senderID)
        senderDeviceID = try container.decodeIfPresent(UUID.self, forKey: .senderDeviceID)
        recipientID = try container.decode(UUID.self, forKey: .recipientID)
        recipientDeviceID = try container.decodeIfPresent(UUID.self, forKey: .recipientDeviceID)
        envelope = try container.decode(MessageEnvelope.self, forKey: .envelope)
        encryptedBlobPath = try container.decodeIfPresent(String.self, forKey: .encryptedBlobPath)
        localEncryptedPackageURL = nil
        localThumbnailURL = nil
        blobSize = try container.decode(Int.self, forKey: .blobSize)
        status = try container.decode(MessageStatus.self, forKey: .status)
        deliveredAt = try container.decodeIfPresent(Date.self, forKey: .deliveredAt)
        blobDeletedAt = try container.decodeIfPresent(Date.self, forKey: .blobDeletedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(senderID, forKey: .senderID)
        try container.encodeIfPresent(senderDeviceID, forKey: .senderDeviceID)
        try container.encode(recipientID, forKey: .recipientID)
        try container.encodeIfPresent(recipientDeviceID, forKey: .recipientDeviceID)
        try container.encode(envelope, forKey: .envelope)
        try container.encodeIfPresent(encryptedBlobPath, forKey: .encryptedBlobPath)
        try container.encode(blobSize, forKey: .blobSize)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(deliveredAt, forKey: .deliveredAt)
        try container.encodeIfPresent(blobDeletedAt, forKey: .blobDeletedAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(expiresAt, forKey: .expiresAt)
    }
}

struct MessageEnvelope: Codable, Hashable {
    var version: Int
    var senderDeviceID: UUID
    var recipientDeviceID: UUID
    var media: EncryptedMediaDescriptor
    var contentKey: ContentKeyEnvelope
    var senderContentKey: ContentKeyEnvelope?
    var createdAt: Date
    var clientMessageID: UUID? = nil
    var senderIdentityDigest: Data? = nil
    var recipientIdentityDigest: Data? = nil
    var authenticationAlgorithm: String? = nil
    var signature: Data? = nil

    static let authenticatedVersion = 2
    static let ed25519Authentication = "Ed25519"

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case senderDeviceID
        case recipientDeviceID
        case media
        case contentKey
        case senderContentKey
        case createdAt
        case clientMessageID
        case senderIdentityDigest
        case recipientIdentityDigest
        case authenticationAlgorithm
        case signature
    }

    init(
        version: Int,
        senderDeviceID: UUID,
        recipientDeviceID: UUID,
        media: EncryptedMediaDescriptor,
        contentKey: ContentKeyEnvelope,
        senderContentKey: ContentKeyEnvelope?,
        createdAt: Date,
        clientMessageID: UUID? = nil,
        senderIdentityDigest: Data? = nil,
        recipientIdentityDigest: Data? = nil,
        authenticationAlgorithm: String? = nil,
        signature: Data? = nil
    ) {
        self.version = version
        self.senderDeviceID = senderDeviceID
        self.recipientDeviceID = recipientDeviceID
        self.media = media
        self.contentKey = contentKey
        self.senderContentKey = senderContentKey
        self.createdAt = createdAt
        self.clientMessageID = clientMessageID
        self.senderIdentityDigest = senderIdentityDigest
        self.recipientIdentityDigest = recipientIdentityDigest
        self.authenticationAlgorithm = authenticationAlgorithm
        self.signature = signature
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowing: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        senderDeviceID = try container.decode(UUID.self, forKey: .senderDeviceID)
        recipientDeviceID = try container.decode(UUID.self, forKey: .recipientDeviceID)
        media = try container.decode(EncryptedMediaDescriptor.self, forKey: .media)
        contentKey = try container.decode(ContentKeyEnvelope.self, forKey: .contentKey)
        senderContentKey = try container.decodeIfPresent(
            ContentKeyEnvelope.self,
            forKey: .senderContentKey
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        clientMessageID = try container.decodeIfPresent(UUID.self, forKey: .clientMessageID)
        senderIdentityDigest = try container.decodeIfPresent(
            Data.self,
            forKey: .senderIdentityDigest
        )
        recipientIdentityDigest = try container.decodeIfPresent(
            Data.self,
            forKey: .recipientIdentityDigest
        )
        authenticationAlgorithm = try container.decodeIfPresent(
            String.self,
            forKey: .authenticationAlgorithm
        )
        signature = try container.decodeIfPresent(Data.self, forKey: .signature)
    }
}

struct EncryptedMediaDescriptor: Codable, Hashable {
    var algorithm: String
    var nonce: Data
    var ciphertextHash: Data?
    var mimeType: String
    var durationSeconds: Double?
    var thumbnail: EncryptedThumbnailEnvelope?

    static let xChaCha20Poly1305 = "XChaCha20-Poly1305"

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case algorithm
        case nonce
        case ciphertextHash
        case mimeType
        case durationSeconds
        case thumbnail
    }

    init(
        algorithm: String,
        nonce: Data,
        ciphertextHash: Data?,
        mimeType: String,
        durationSeconds: Double?,
        thumbnail: EncryptedThumbnailEnvelope?
    ) {
        self.algorithm = algorithm
        self.nonce = nonce
        self.ciphertextHash = ciphertextHash
        self.mimeType = mimeType
        self.durationSeconds = durationSeconds
        self.thumbnail = thumbnail
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowing: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        nonce = try container.decode(Data.self, forKey: .nonce)
        ciphertextHash = try container.decodeIfPresent(Data.self, forKey: .ciphertextHash)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        thumbnail = try container.decodeIfPresent(
            EncryptedThumbnailEnvelope.self,
            forKey: .thumbnail
        )
    }
}

struct EncryptedThumbnailEnvelope: Codable, Hashable {
    var algorithm: String
    var nonce: Data
    var encryptedBlobPath: String?
    var ciphertextHash: Data?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case algorithm
        case nonce
        case encryptedBlobPath
        case ciphertextHash
    }

    init(
        algorithm: String,
        nonce: Data,
        encryptedBlobPath: String?,
        ciphertextHash: Data?
    ) {
        self.algorithm = algorithm
        self.nonce = nonce
        self.encryptedBlobPath = encryptedBlobPath
        self.ciphertextHash = ciphertextHash
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowing: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        nonce = try container.decode(Data.self, forKey: .nonce)
        encryptedBlobPath = try container.decodeIfPresent(
            String.self,
            forKey: .encryptedBlobPath
        )
        ciphertextHash = try container.decodeIfPresent(Data.self, forKey: .ciphertextHash)
    }
}

struct ContentKeyEnvelope: Codable, Hashable {
    var algorithm: String
    var encryptedContentKey: Data
    var recipientPublicKeyFingerprint: String?

    static let sealedBox = "crypto_box_seal"

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case algorithm
        case encryptedContentKey
        case recipientPublicKeyFingerprint
    }

    init(
        algorithm: String,
        encryptedContentKey: Data,
        recipientPublicKeyFingerprint: String?
    ) {
        self.algorithm = algorithm
        self.encryptedContentKey = encryptedContentKey
        self.recipientPublicKeyFingerprint = recipientPublicKeyFingerprint
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(allowing: CodingKeys.allCases)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        encryptedContentKey = try container.decode(Data.self, forKey: .encryptedContentKey)
        recipientPublicKeyFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .recipientPublicKeyFingerprint
        )
    }
}

struct ConversationSummary: Identifiable, Hashable {
    var id: UUID { contact.id }

    var contact: Contact
    var latestMessage: Message?
    var unreadCount: Int
}

struct AuthSession: Codable, Hashable {
    var user: SpeakeasyUser
    var device: SpeakeasyDevice
    var bearerToken: String
    var expiresAt: Date?
}

struct LoginChallenge: Codable, Hashable {
    var challengeID: UUID
    var challenge: Data
    var expiresAt: Date
}

struct ContactInvite: Codable, Hashable {
    var code: String
    var inviteURL: URL?
    var expiresAt: Date?
}

struct EmptyResponse: Codable, Hashable {}

private struct AnyWireCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension Decoder {
    func rejectUnknownKeys<Keys: CodingKey>(allowing keys: [Keys]) throws {
        let allowedKeys = Set(keys.map(\.stringValue))
        let wireContainer = try container(keyedBy: AnyWireCodingKey.self)
        let unknownKeys = wireContainer.allKeys
            .map(\.stringValue)
            .filter { !allowedKeys.contains($0) }
            .sorted()
        guard unknownKeys.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unknown authenticated wire fields: \(unknownKeys.joined(separator: ", "))"
            ))
        }
    }
}
