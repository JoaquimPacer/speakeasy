import Foundation
import Security
import Sodium

enum MessageReplayStoreError: Error, LocalizedError {
    case invalidField(String)
    case replayDetected
    case missingLocalRecord
    case mismatchedLocalRecord
    case corruptStoredRecord
    case unsupportedStoredRecordVersion(Int)
    case keychain(OSStatus)
    case hashingFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidField(let field):
            return "The replay-protection record has an invalid \(field)."
        case .replayDetected:
            return "This authenticated message was already accepted from the relay."
        case .missingLocalRecord:
            return "This local message has no authenticated receipt record and cannot be played."
        case .mismatchedLocalRecord:
            return "This local message does not match its authenticated receipt record."
        case .corruptStoredRecord:
            return "A stored replay-protection record is invalid."
        case .unsupportedStoredRecordVersion(let version):
            return "Replay-protection record version \(version) is not supported."
        case .keychain(let status):
            return "The replay-protection Keychain operation failed with status \(status)."
        case .hashingFailed:
            return "The replay-protection key could not be calculated."
        case .encodingFailed:
            return "The replay-protection record could not be encoded."
        }
    }
}

enum MessageReplayReservation: Equatable {
    /// No receipt existed for this authenticated sender/client-message tuple.
    case new

    /// An exact pending receipt survived an interrupted receive attempt.
    case recoveringPending
}

/// Persists one Keychain item for each authenticated network-receipt tuple.
///
/// The tuple is `(relayScopeHash, localDeviceID, senderIdentityDigest,
/// clientMessageID)`. The stored receipt also binds the relay's server ID and
/// the exact authenticated 64-byte Message Envelope v2 signature.
///
/// A receive operation reserves the tuple before committing its encrypted file.
/// Local validation may promote an exact pending receipt to committed, which
/// recovers a crash after the file commit but before the Keychain transition.
/// Once committed, another network reservation is always a replay; local
/// playback remains allowed only for the exact stored receipt.
///
/// Pending receipts are intentionally retained when receive work fails. An
/// exact retry recovers them; deleting them would race another in-flight exact
/// receiver and could leave durable ciphertext without a receipt. Before local
/// validation is called, the caller must hash the local ciphertext and compare
/// it with the authenticated envelope hash. Filename presence is not proof of
/// an exact file and must never authorize the pending-to-committed transition.
protocol MessageReplayStoring {
    @discardableResult
    func reserveNetworkReceipt(
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) async throws -> MessageReplayReservation

    func markPendingReceiptCommitted(
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) async throws

    func validateLocalMessage(
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) async throws

    func removeAll() async throws
}

actor KeychainMessageReplayStore: MessageReplayStoring {
    // Version 1 receipts had no signature or pending/committed state. Decoding
    // or validation fails closed instead of silently trusting those records.
    private static let currentRecordVersion = 2
    private static let digestByteCount = 32
    private static let signatureByteCount = 64
    private static let accountDomain = Data("KITHRA/MESSAGE-REPLAY-KEY/V1\0".utf8)

    private let service: String
    private let accessGroup: String?
    private let sodium = Sodium()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String = "com.speakeasy.message-replay.v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    func reserveNetworkReceipt(
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) throws -> MessageReplayReservation {
        let expected = try makeRecord(
            state: .pending,
            clientMessageID: clientMessageID,
            serverMessageID: serverMessageID,
            senderIdentityDigest: senderIdentityDigest,
            relayScopeHash: relayScopeHash,
            localDeviceID: localDeviceID,
            authenticatedEnvelopeSignature: authenticatedEnvelopeSignature
        )
        let account = try account(for: expected)

        if let stored = try loadValidatedRecord(account: account) {
            return try reservation(for: stored, expected: expected)
        }

        do {
            try add(expected, account: account)
            return .new
        } catch MessageReplayStoreError.replayDetected {
            // Another store instance or process can win between our lookup and
            // SecItemAdd. Classify the now-existing record instead of treating
            // an exact pending reservation as an attack.
            guard let stored = try loadValidatedRecord(account: account) else {
                throw MessageReplayStoreError.replayDetected
            }
            return try reservation(for: stored, expected: expected)
        }
    }

    func markPendingReceiptCommitted(
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) throws {
        let expected = try makeRecord(
            state: .pending,
            clientMessageID: clientMessageID,
            serverMessageID: serverMessageID,
            senderIdentityDigest: senderIdentityDigest,
            relayScopeHash: relayScopeHash,
            localDeviceID: localDeviceID,
            authenticatedEnvelopeSignature: authenticatedEnvelopeSignature
        )
        let account = try account(for: expected)
        guard var stored = try loadValidatedRecord(account: account) else {
            throw MessageReplayStoreError.missingLocalRecord
        }
        guard exactReceiptMatches(stored, expected) else {
            throw MessageReplayStoreError.replayDetected
        }

        switch stored.state {
        case .pending:
            stored.state = .committed
            stored.committedAt = Date()
            try update(stored, account: account)
        case .committed:
            // The exact transition is idempotent in case the app was
            // interrupted after SecItemUpdate succeeded but before return.
            return
        }
    }

    func validateLocalMessage(
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) throws {
        let expected = try makeRecord(
            state: .committed,
            clientMessageID: clientMessageID,
            serverMessageID: serverMessageID,
            senderIdentityDigest: senderIdentityDigest,
            relayScopeHash: relayScopeHash,
            localDeviceID: localDeviceID,
            authenticatedEnvelopeSignature: authenticatedEnvelopeSignature
        )
        let account = try account(for: expected)
        guard var stored = try loadValidatedRecord(account: account) else {
            throw MessageReplayStoreError.missingLocalRecord
        }
        guard exactReceiptMatches(stored, expected) else {
            if stored.state == .pending {
                throw MessageReplayStoreError.replayDetected
            }
            throw MessageReplayStoreError.mismatchedLocalRecord
        }

        if stored.state == .pending {
            // The caller invokes local validation only after hashing the local
            // ciphertext and comparing it with the authenticated envelope
            // hash. That proves the exact file commit finished before a prior
            // crash, so finish the receipt transition atomically in Keychain.
            stored.state = .committed
            stored.committedAt = Date()
            try update(stored, account: account)
        }
    }

    func removeAll() throws {
        let status = SecItemDelete(serviceQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MessageReplayStoreError.keychain(status)
        }
    }

    private func reservation(
        for stored: StoredMessageReceipt,
        expected: StoredMessageReceipt
    ) throws -> MessageReplayReservation {
        guard stored.state == .pending, exactReceiptMatches(stored, expected) else {
            throw MessageReplayStoreError.replayDetected
        }
        return .recoveringPending
    }

    private func makeRecord(
        state: StoredMessageReceipt.State,
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) throws -> StoredMessageReceipt {
        guard clientMessageID != Self.zeroUUID else {
            throw MessageReplayStoreError.invalidField("client message ID")
        }
        guard serverMessageID != Self.zeroUUID else {
            throw MessageReplayStoreError.invalidField("server message ID")
        }
        guard localDeviceID != Self.zeroUUID else {
            throw MessageReplayStoreError.invalidField("local device ID")
        }
        guard senderIdentityDigest.count == Self.digestByteCount else {
            throw MessageReplayStoreError.invalidField("sender identity digest")
        }
        guard relayScopeHash.count == Self.digestByteCount else {
            throw MessageReplayStoreError.invalidField("relay scope hash")
        }
        guard authenticatedEnvelopeSignature.count == Self.signatureByteCount else {
            throw MessageReplayStoreError.invalidField("authenticated envelope signature")
        }

        let now = Date()
        return StoredMessageReceipt(
            formatVersion: Self.currentRecordVersion,
            state: state,
            clientMessageID: clientMessageID,
            serverMessageID: serverMessageID,
            senderIdentityDigest: senderIdentityDigest,
            relayScopeHash: relayScopeHash,
            localDeviceID: localDeviceID,
            authenticatedEnvelopeSignature: authenticatedEnvelopeSignature,
            reservedAt: now,
            committedAt: state == .committed ? now : nil
        )
    }

    private func exactReceiptMatches(
        _ stored: StoredMessageReceipt,
        _ expected: StoredMessageReceipt
    ) -> Bool {
        stored.clientMessageID == expected.clientMessageID &&
            stored.serverMessageID == expected.serverMessageID &&
            stored.localDeviceID == expected.localDeviceID &&
            constantTimeEquals(stored.senderIdentityDigest, expected.senderIdentityDigest) &&
            constantTimeEquals(stored.relayScopeHash, expected.relayScopeHash) &&
            constantTimeEquals(
                stored.authenticatedEnvelopeSignature,
                expected.authenticatedEnvelopeSignature
            )
    }

    private func validate(_ record: StoredMessageReceipt, account: String) throws {
        guard record.formatVersion == Self.currentRecordVersion else {
            throw MessageReplayStoreError.unsupportedStoredRecordVersion(record.formatVersion)
        }
        guard record.clientMessageID != Self.zeroUUID,
              record.serverMessageID != Self.zeroUUID,
              record.localDeviceID != Self.zeroUUID,
              record.senderIdentityDigest.count == Self.digestByteCount,
              record.relayScopeHash.count == Self.digestByteCount,
              record.authenticatedEnvelopeSignature.count == Self.signatureByteCount,
              (record.state == .pending && record.committedAt == nil) ||
                  (record.state == .committed && record.committedAt != nil),
              try self.account(for: record) == account else {
            throw MessageReplayStoreError.corruptStoredRecord
        }
    }

    private func account(for record: StoredMessageReceipt) throws -> String {
        var bytes = Self.accountDomain
        bytes.appendLengthPrefixed(record.relayScopeHash)
        bytes.appendUUID(record.localDeviceID)
        bytes.appendLengthPrefixed(record.senderIdentityDigest)
        bytes.appendUUID(record.clientMessageID)
        guard let digest = sodium.genericHash.hash(
            message: Array(bytes),
            outputLength: Self.digestByteCount
        ) else {
            throw MessageReplayStoreError.hashingFailed
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEquals(_ first: Data, _ second: Data) -> Bool {
        sodium.utils.equals(Array(first), Array(second))
    }

    private func add(_ record: StoredMessageReceipt, account: String) throws {
        var query = itemQuery(account: account)
        query[kSecValueData as String] = try encoded(record)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw MessageReplayStoreError.replayDetected
        default:
            throw MessageReplayStoreError.keychain(status)
        }
    }

    private func update(_ record: StoredMessageReceipt, account: String) throws {
        let attributes = [kSecValueData as String: try encoded(record)]
        let status = SecItemUpdate(
            itemQuery(account: account) as CFDictionary,
            attributes as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw MessageReplayStoreError.missingLocalRecord
        default:
            throw MessageReplayStoreError.keychain(status)
        }
    }

    private func encoded(_ record: StoredMessageReceipt) throws -> Data {
        do {
            return try encoder.encode(record)
        } catch {
            throw MessageReplayStoreError.encodingFailed
        }
    }

    private func loadValidatedRecord(account: String) throws -> StoredMessageReceipt? {
        guard let record = try loadRecord(account: account) else {
            return nil
        }
        try validate(record, account: account)
        return record
    }

    private func loadRecord(account: String) throws -> StoredMessageReceipt? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MessageReplayStoreError.keychain(status)
        }
        guard let data = item as? Data else {
            throw MessageReplayStoreError.corruptStoredRecord
        }
        do {
            return try decoder.decode(StoredMessageReceipt.self, from: data)
        } catch {
            throw MessageReplayStoreError.corruptStoredRecord
        }
    }

    private func serviceQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func itemQuery(account: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

private struct StoredMessageReceipt: Codable {
    enum State: String, Codable {
        case pending
        case committed
    }

    let formatVersion: Int
    var state: State
    let clientMessageID: UUID
    let serverMessageID: UUID
    let senderIdentityDigest: Data
    let relayScopeHash: Data
    let localDeviceID: UUID
    let authenticatedEnvelopeSignature: Data
    let reservedAt: Date
    var committedAt: Date?
}

private extension Data {
    mutating func appendLengthPrefixed(_ value: Data) {
        let length = UInt32(value.count)
        append(UInt8((length >> 24) & 0xff))
        append(UInt8((length >> 16) & 0xff))
        append(UInt8((length >> 8) & 0xff))
        append(UInt8(length & 0xff))
        append(value)
    }

    mutating func appendUUID(_ value: UUID) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { append(contentsOf: $0) }
    }
}
