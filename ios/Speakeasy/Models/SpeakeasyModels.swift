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
    var localEncryptedPackageURL: URL?
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
}

struct MessageEnvelope: Codable, Hashable {
    var version: Int
    var senderDeviceID: UUID
    var recipientDeviceID: UUID
    var media: EncryptedMediaDescriptor
    var contentKey: ContentKeyEnvelope
    var senderContentKey: ContentKeyEnvelope?
    var createdAt: Date
}

struct EncryptedMediaDescriptor: Codable, Hashable {
    var algorithm: String
    var nonce: Data
    var ciphertextHash: Data?
    var mimeType: String
    var durationSeconds: Double?
    var thumbnail: EncryptedThumbnailEnvelope?

    static let xChaCha20Poly1305 = "XChaCha20-Poly1305"
}

struct EncryptedThumbnailEnvelope: Codable, Hashable {
    var algorithm: String
    var nonce: Data
    var encryptedBlobPath: String?
    var ciphertextHash: Data?
}

struct ContentKeyEnvelope: Codable, Hashable {
    var algorithm: String
    var encryptedContentKey: Data
    var recipientPublicKeyFingerprint: String?

    static let sealedBox = "crypto_box_seal"
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
