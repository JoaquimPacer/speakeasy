import Foundation
import Security
import Sodium

enum DeviceKeyManagerError: Error, LocalizedError {
    case identityNotFound
    case corruptStoredIdentity
    case keychain(OSStatus)
    case cryptoOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .identityNotFound:
            return "No device identity has been stored on this device."
        case .corruptStoredIdentity:
            return "The stored device identity could not be decoded."
        case .keychain(let status):
            return "Keychain operation failed with status \(status)."
        case .cryptoOperationFailed(let operation):
            return "\(operation) failed."
        }
    }
}

protocol DeviceKeyManaging {
    func currentIdentity() async throws -> DevicePublicIdentity?
    func loadOrCreateIdentity() async throws -> DevicePublicIdentity
    func bindRegisteredDeviceID(_ deviceID: UUID) async throws -> DevicePublicIdentity
    func storeGeneratedIdentity(
        deviceID: UUID?,
        encryptionPublicKey: Data,
        encryptionPrivateKey: Data,
        signingPublicKey: Data,
        signingPrivateKey: Data
    ) async throws -> DevicePublicIdentity
    func removeIdentity() async throws
    func makeLoginChallengeResponse(challenge: Data) async throws -> Data
    func encryptContentKey(_ contentKey: Data, recipientPublicKey: Data) async throws -> ContentKeyEnvelope
    func decryptContentKey(from envelope: ContentKeyEnvelope) async throws -> Data
}

final class KeychainDeviceKeyManager: DeviceKeyManaging {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let sodium = Sodium()

    init(
        service: String = "com.speakeasy.device-key",
        account: String = "primary-x25519",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    func currentIdentity() async throws -> DevicePublicIdentity? {
        try loadStoredRecord()?.publicIdentity
    }

    func loadOrCreateIdentity() async throws -> DevicePublicIdentity {
        if let identity = try await currentIdentity() {
            return identity
        }

        guard let encryptionKeyPair = sodium.box.keyPair() else {
            throw DeviceKeyManagerError.cryptoOperationFailed("Generating X25519 device encryption keys")
        }
        guard let signingKeyPair = sodium.sign.keyPair() else {
            throw DeviceKeyManagerError.cryptoOperationFailed("Generating Ed25519 device signing keys")
        }

        return try await storeGeneratedIdentity(
            deviceID: nil,
            encryptionPublicKey: Data(encryptionKeyPair.publicKey),
            encryptionPrivateKey: Data(encryptionKeyPair.secretKey),
            signingPublicKey: Data(signingKeyPair.publicKey),
            signingPrivateKey: Data(signingKeyPair.secretKey)
        )
    }

    func bindRegisteredDeviceID(_ deviceID: UUID) async throws -> DevicePublicIdentity {
        guard var record = try loadStoredRecord() else {
            throw DeviceKeyManagerError.identityNotFound
        }

        record.deviceID = deviceID
        try save(record)
        return record.publicIdentity
    }

    func storeGeneratedIdentity(
        deviceID: UUID?,
        encryptionPublicKey: Data,
        encryptionPrivateKey: Data,
        signingPublicKey: Data,
        signingPrivateKey: Data
    ) async throws -> DevicePublicIdentity {
        let record = StoredDeviceKeyRecord(
            deviceID: deviceID,
            encryptionPublicKey: encryptionPublicKey,
            encryptionPrivateKey: encryptionPrivateKey,
            signingPublicKey: signingPublicKey,
            signingPrivateKey: signingPrivateKey,
            createdAt: Date()
        )

        try save(record)
        return record.publicIdentity
    }

    func removeIdentity() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyManagerError.keychain(status)
        }
    }

    func makeLoginChallengeResponse(challenge: Data) async throws -> Data {
        guard let record = try loadStoredRecord() else {
            throw DeviceKeyManagerError.identityNotFound
        }
        guard let signature = sodium.sign.signature(
            message: Array(challenge),
            secretKey: Array(record.signingPrivateKey)
        ) else {
            throw DeviceKeyManagerError.cryptoOperationFailed("Signing the relay auth challenge")
        }

        return Data(signature)
    }

    func encryptContentKey(_ contentKey: Data, recipientPublicKey: Data) async throws -> ContentKeyEnvelope {
        guard let sealedContentKey = sodium.box.seal(
            message: Array(contentKey),
            recipientPublicKey: Array(recipientPublicKey)
        ) else {
            throw DeviceKeyManagerError.cryptoOperationFailed("Wrapping the message content key")
        }

        return ContentKeyEnvelope(
            algorithm: ContentKeyEnvelope.sealedBox,
            encryptedContentKey: Data(sealedContentKey),
            recipientPublicKeyFingerprint: Data(recipientPublicKey.prefix(16)).base64EncodedString()
        )
    }

    func decryptContentKey(from envelope: ContentKeyEnvelope) async throws -> Data {
        guard envelope.algorithm == ContentKeyEnvelope.sealedBox else {
            throw DeviceKeyManagerError.cryptoOperationFailed("Recognizing the content key envelope algorithm")
        }
        guard let record = try loadStoredRecord() else {
            throw DeviceKeyManagerError.identityNotFound
        }
        guard let contentKey = sodium.box.open(
            anonymousCipherText: Array(envelope.encryptedContentKey),
            recipientPublicKey: Array(record.encryptionPublicKey),
            recipientSecretKey: Array(record.encryptionPrivateKey)
        ) else {
            throw DeviceKeyManagerError.cryptoOperationFailed("Unwrapping the message content key")
        }

        return Data(contentKey)
    }

    private func loadStoredRecord() throws -> StoredDeviceKeyRecord? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw DeviceKeyManagerError.keychain(status)
        }

        guard let data = item as? Data else {
            throw DeviceKeyManagerError.corruptStoredIdentity
        }

        do {
            return try decoder.decode(StoredDeviceKeyRecord.self, from: data)
        } catch {
            throw DeviceKeyManagerError.corruptStoredIdentity
        }
    }

    private func save(_ record: StoredDeviceKeyRecord) throws {
        let data = try encoder.encode(record)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }

        if status == errSecDuplicateItem {
            let attributes = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ] as [String: Any]
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw DeviceKeyManagerError.keychain(updateStatus)
            }
            return
        }

        throw DeviceKeyManagerError.keychain(status)
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }
}

private struct StoredDeviceKeyRecord: Codable, Hashable {
    var deviceID: UUID?
    var encryptionPublicKey: Data
    var encryptionPrivateKey: Data
    var signingPublicKey: Data
    var signingPrivateKey: Data
    var createdAt: Date

    var publicIdentity: DevicePublicIdentity {
        DevicePublicIdentity(
            deviceID: deviceID,
            encryptionPublicKey: encryptionPublicKey,
            signingPublicKey: signingPublicKey,
            createdAt: createdAt
        )
    }
}
