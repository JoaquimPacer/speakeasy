import Foundation
import Security
import Sodium

enum ContactTrustState: String, Codable, Hashable {
    case unverified
    case verified
    case keyChanged
}

enum ContactVerificationMethod: String, Codable, CaseIterable, Hashable {
    case qrCode
    case safetyNumberComparison
}

struct ContactTrustAssessment: Hashable {
    let state: ContactTrustState
    let candidateIdentity: ContactVerificationIdentity
    let trustedIdentity: ContactVerificationIdentity?
    let verificationMethod: ContactVerificationMethod?
    let verifiedAt: Date?
}

/// Stable identifiers for removing every trust record associated with a contact.
///
/// This deliberately excludes usernames and public keys because those values are
/// relay-controlled candidates. A malformed or changed candidate must never make
/// it impossible to remove an older verified pin.
struct ContactTrustRemovalScope: Hashable {
    let relayScopeHash: Data
    let localUserID: UUID
    let localDeviceID: UUID
    let remoteUserID: UUID
    let remoteDeviceID: UUID

    init(
        relayURL: URL,
        localUserID: UUID,
        localDeviceID: UUID,
        remoteUserID: UUID,
        remoteDeviceID: UUID
    ) throws {
        relayScopeHash = try ContactVerificationIdentity.canonicalRelayScopeHash(for: relayURL)
        self.localUserID = localUserID
        self.localDeviceID = localDeviceID
        self.remoteUserID = remoteUserID
        self.remoteDeviceID = remoteDeviceID
    }

    init(context: ContactVerificationContext) {
        relayScopeHash = context.localIdentity.relayScopeHash
        localUserID = context.localIdentity.userID
        localDeviceID = context.localIdentity.deviceID
        remoteUserID = context.remoteIdentity.userID
        remoteDeviceID = context.remoteIdentity.deviceID
    }
}

enum ContactTrustStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case corruptStoredRecord
    case unsupportedStoredRecordVersion(Int)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The contact-verification Keychain operation failed with status \(status)."
        case .corruptStoredRecord:
            return "A stored contact-verification record is invalid."
        case .unsupportedStoredRecordVersion(let version):
            return "Contact-verification record version \(version) is not supported."
        case .encodingFailed:
            return "The contact-verification record could not be encoded."
        }
    }
}

/// Injectable storage boundary for contact trust decisions.
///
/// Calling `observe` never grants trust. Only `recordVerification` promotes the exact
/// currently observed local/remote identity pair after the UI has successfully validated
/// a QR payload or the users have compared the complete 60-digit safety number.
protocol ContactTrustStoring {
    @discardableResult
    func observe(_ context: ContactVerificationContext) throws -> ContactTrustAssessment

    @discardableResult
    func recordVerification(
        _ context: ContactVerificationContext,
        method: ContactVerificationMethod
    ) throws -> ContactTrustAssessment

    func trustedIdentity(for context: ContactVerificationContext) throws -> ContactVerificationIdentity?
    func status(for context: ContactVerificationContext) throws -> ContactTrustState
    func removeContact(_ scope: ContactTrustRemovalScope) throws
    func removeAll() throws
}

extension ContactTrustStoring {
    @discardableResult
    func observe(
        contact: Contact,
        localDeviceIdentity: DevicePublicIdentity,
        localUser: SpeakeasyUser,
        relayURL: URL
    ) throws -> ContactTrustAssessment {
        try observe(ContactVerificationContext(
            relayURL: relayURL,
            localUser: localUser,
            localDeviceIdentity: localDeviceIdentity,
            contact: contact
        ))
    }

    @discardableResult
    func recordVerification(
        contact: Contact,
        localDeviceIdentity: DevicePublicIdentity,
        localUser: SpeakeasyUser,
        relayURL: URL,
        method: ContactVerificationMethod
    ) throws -> ContactTrustAssessment {
        try recordVerification(
            ContactVerificationContext(
                relayURL: relayURL,
                localUser: localUser,
                localDeviceIdentity: localDeviceIdentity,
                contact: contact
            ),
            method: method
        )
    }

    func trustedIdentity(
        for contact: Contact,
        localDeviceIdentity: DevicePublicIdentity,
        localUser: SpeakeasyUser,
        relayURL: URL
    ) throws -> ContactVerificationIdentity? {
        try trustedIdentity(for: ContactVerificationContext(
            relayURL: relayURL,
            localUser: localUser,
            localDeviceIdentity: localDeviceIdentity,
            contact: contact
        ))
    }

    func status(
        for contact: Contact,
        localDeviceIdentity: DevicePublicIdentity,
        localUser: SpeakeasyUser,
        relayURL: URL
    ) throws -> ContactTrustState {
        try status(for: ContactVerificationContext(
            relayURL: relayURL,
            localUser: localUser,
            localDeviceIdentity: localDeviceIdentity,
            contact: contact
        ))
    }

    func removeContact(
        _ contact: Contact,
        localDeviceIdentity: DevicePublicIdentity,
        localUser: SpeakeasyUser,
        relayURL: URL
    ) throws {
        guard let localDeviceID = localDeviceIdentity.deviceID else {
            throw ContactVerificationError.missingLocalDeviceID
        }
        try removeContact(ContactTrustRemovalScope(
            relayURL: relayURL,
            localUserID: localUser.id,
            localDeviceID: localDeviceID,
            remoteUserID: contact.contactID,
            remoteDeviceID: contact.deviceID
        ))
    }

    func removeContact(_ context: ContactVerificationContext) throws {
        try removeContact(ContactTrustRemovalScope(context: context))
    }
}

final class KeychainContactTrustStore: ContactTrustStoring {
    private static let currentRecordVersion = 1

    private let service: String
    private let accessGroup: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(
        service: String = "com.speakeasy.contact-verification.v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    func observe(_ context: ContactVerificationContext) throws -> ContactTrustAssessment {
        lock.lock()
        defer { lock.unlock() }

        let namespace = ContactTrustNamespace(context: context)
        let account = try namespace.account
        let now = Date()

        var record: StoredContactTrustRecord
        if let existing = try loadRecord(account: account) {
            record = existing
            record.candidateLocalIdentity = context.localIdentity
            record.candidateRemoteIdentity = context.remoteIdentity
            record.lastObservedAt = now
        } else {
            let previousTrust = try latestTrustedRecord(matching: namespace)
            record = StoredContactTrustRecord(
                formatVersion: Self.currentRecordVersion,
                namespace: namespace,
                candidateLocalIdentity: context.localIdentity,
                candidateRemoteIdentity: context.remoteIdentity,
                trustedLocalIdentity: previousTrust?.trustedLocalIdentity,
                trustedRemoteIdentity: previousTrust?.trustedRemoteIdentity,
                verificationMethod: previousTrust?.verificationMethod,
                verifiedAt: previousTrust?.verifiedAt,
                lastObservedAt: now
            )
        }

        try validate(record, account: account)
        try save(record, account: account)
        return assessment(for: record)
    }

    @discardableResult
    func recordVerification(
        _ context: ContactVerificationContext,
        method: ContactVerificationMethod
    ) throws -> ContactTrustAssessment {
        lock.lock()
        defer { lock.unlock() }

        let namespace = ContactTrustNamespace(context: context)
        let account = try namespace.account
        let now = Date()
        let record = StoredContactTrustRecord(
            formatVersion: Self.currentRecordVersion,
            namespace: namespace,
            candidateLocalIdentity: context.localIdentity,
            candidateRemoteIdentity: context.remoteIdentity,
            trustedLocalIdentity: context.localIdentity,
            trustedRemoteIdentity: context.remoteIdentity,
            verificationMethod: method,
            verifiedAt: now,
            lastObservedAt: now
        )

        // V1 has one active device per contact. Remove any older device-scoped record
        // for this relationship before promoting the newly verified identity.
        try deleteRecords(matching: namespace)
        try validate(record, account: account)
        try save(record, account: account)
        return assessment(for: record)
    }

    func trustedIdentity(for context: ContactVerificationContext) throws -> ContactVerificationIdentity? {
        lock.lock()
        defer { lock.unlock() }

        let namespace = ContactTrustNamespace(context: context)
        if let exactRecord = try loadRecord(account: namespace.account) {
            return exactRecord.trustedRemoteIdentity
        }
        return try latestTrustedRecord(matching: namespace)?.trustedRemoteIdentity
    }

    func status(for context: ContactVerificationContext) throws -> ContactTrustState {
        lock.lock()
        defer { lock.unlock() }

        let namespace = ContactTrustNamespace(context: context)
        if var exactRecord = try loadRecord(account: namespace.account) {
            exactRecord.candidateLocalIdentity = context.localIdentity
            exactRecord.candidateRemoteIdentity = context.remoteIdentity
            return assessment(for: exactRecord).state
        }

        guard let previousTrust = try latestTrustedRecord(matching: namespace) else {
            return .unverified
        }
        let transientRecord = StoredContactTrustRecord(
            formatVersion: Self.currentRecordVersion,
            namespace: namespace,
            candidateLocalIdentity: context.localIdentity,
            candidateRemoteIdentity: context.remoteIdentity,
            trustedLocalIdentity: previousTrust.trustedLocalIdentity,
            trustedRemoteIdentity: previousTrust.trustedRemoteIdentity,
            verificationMethod: previousTrust.verificationMethod,
            verifiedAt: previousTrust.verifiedAt,
            lastObservedAt: Date()
        )
        return assessment(for: transientRecord).state
    }

    func removeContact(_ scope: ContactTrustRemovalScope) throws {
        lock.lock()
        defer { lock.unlock() }

        let namespace = ContactTrustNamespace(removalScope: scope)

        // Delete the exact stable account first. This does not decode the stored
        // value, so a corrupt candidate record cannot preserve its pin. Then
        // remove any older device-scoped records for the same V1 relationship.
        try deleteRecord(account: namespace.account)
        try deleteRecords(matching: namespace)
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }

        let status = SecItemDelete(serviceQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ContactTrustStoreError.keychain(status)
        }
    }

    private func assessment(for record: StoredContactTrustRecord) -> ContactTrustAssessment {
        let state: ContactTrustState
        if let trustedLocalIdentity = record.trustedLocalIdentity,
           let trustedRemoteIdentity = record.trustedRemoteIdentity {
            state = trustedLocalIdentity.constantTimeEquals(record.candidateLocalIdentity) &&
                trustedRemoteIdentity.constantTimeEquals(record.candidateRemoteIdentity)
                ? .verified
                : .keyChanged
        } else {
            state = .unverified
        }

        return ContactTrustAssessment(
            state: state,
            candidateIdentity: record.candidateRemoteIdentity,
            trustedIdentity: record.trustedRemoteIdentity,
            verificationMethod: record.verificationMethod,
            verifiedAt: record.verifiedAt
        )
    }

    private func latestTrustedRecord(
        matching namespace: ContactTrustNamespace
    ) throws -> StoredContactTrustRecord? {
        try allRecords()
            .filter { _, record in
                record.namespace.matchesRelationship(namespace) &&
                    record.trustedLocalIdentity != nil &&
                    record.trustedRemoteIdentity != nil
            }
            .map(\.record)
            .max { first, second in
                (first.verifiedAt ?? .distantPast) < (second.verifiedAt ?? .distantPast)
            }
    }

    private func deleteRecords(matching namespace: ContactTrustNamespace) throws {
        let accounts = try allRecords().compactMap { account, record in
            record.namespace.matchesRelationship(namespace) ? account : nil
        }
        for account in accounts {
            try deleteRecord(account: account)
        }
    }

    private func deleteRecord(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ContactTrustStoreError.keychain(status)
        }
    }

    private func loadRecord(account: String) throws -> StoredContactTrustRecord? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ContactTrustStoreError.keychain(status)
        }
        guard let data = item as? Data else {
            throw ContactTrustStoreError.corruptStoredRecord
        }

        let record = try decode(data)
        try validate(record, account: account)
        return record
    }

    private func allRecords() throws -> [(account: String, record: StoredContactTrustRecord)] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw ContactTrustStoreError.keychain(status)
        }

        let dictionaries: [[String: Any]]
        if let items = item as? [[String: Any]] {
            dictionaries = items
        } else if let singleItem = item as? [String: Any] {
            dictionaries = [singleItem]
        } else {
            throw ContactTrustStoreError.corruptStoredRecord
        }

        return try dictionaries.map { dictionary in
            guard let account = dictionary[kSecAttrAccount as String] as? String,
                  let data = dictionary[kSecValueData as String] as? Data else {
                throw ContactTrustStoreError.corruptStoredRecord
            }
            let record = try decode(data)
            try validate(record, account: account)
            return (account: account, record: record)
        }
    }

    private func decode(_ data: Data) throws -> StoredContactTrustRecord {
        do {
            return try decoder.decode(StoredContactTrustRecord.self, from: data)
        } catch let error as ContactTrustStoreError {
            throw error
        } catch {
            throw ContactTrustStoreError.corruptStoredRecord
        }
    }

    private func save(_ record: StoredContactTrustRecord, account: String) throws {
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw ContactTrustStoreError.encodingFailed
        }

        var query = itemQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(
                itemQuery(account: account) as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw ContactTrustStoreError.keychain(updateStatus)
            }
            return
        }
        throw ContactTrustStoreError.keychain(status)
    }

    private func validate(_ record: StoredContactTrustRecord, account: String) throws {
        guard record.formatVersion == Self.currentRecordVersion else {
            throw ContactTrustStoreError.unsupportedStoredRecordVersion(record.formatVersion)
        }
        guard try record.namespace.account == account,
              record.namespace.containsCandidate(
                  local: record.candidateLocalIdentity,
                  remote: record.candidateRemoteIdentity
              ),
              (record.trustedLocalIdentity == nil) == (record.trustedRemoteIdentity == nil),
              (record.trustedLocalIdentity == nil) == (record.verificationMethod == nil),
              (record.trustedLocalIdentity == nil) == (record.verifiedAt == nil) else {
            throw ContactTrustStoreError.corruptStoredRecord
        }

        if let trustedLocal = record.trustedLocalIdentity,
           let trustedRemote = record.trustedRemoteIdentity {
            guard record.namespace.containsTrusted(local: trustedLocal, remote: trustedRemote) else {
                throw ContactTrustStoreError.corruptStoredRecord
            }
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
}

private struct StoredContactTrustRecord: Codable, Hashable {
    let formatVersion: Int
    let namespace: ContactTrustNamespace
    var candidateLocalIdentity: ContactVerificationIdentity
    var candidateRemoteIdentity: ContactVerificationIdentity
    let trustedLocalIdentity: ContactVerificationIdentity?
    let trustedRemoteIdentity: ContactVerificationIdentity?
    let verificationMethod: ContactVerificationMethod?
    let verifiedAt: Date?
    var lastObservedAt: Date
}

private struct ContactTrustNamespace: Codable, Hashable {
    let relayScopeHash: Data
    let localUserID: UUID
    let localDeviceID: UUID
    let remoteUserID: UUID
    let remoteDeviceID: UUID

    init(context: ContactVerificationContext) {
        relayScopeHash = context.localIdentity.relayScopeHash
        localUserID = context.localIdentity.userID
        localDeviceID = context.localIdentity.deviceID
        remoteUserID = context.remoteIdentity.userID
        remoteDeviceID = context.remoteIdentity.deviceID
    }

    init(removalScope: ContactTrustRemovalScope) {
        relayScopeHash = removalScope.relayScopeHash
        localUserID = removalScope.localUserID
        localDeviceID = removalScope.localDeviceID
        remoteUserID = removalScope.remoteUserID
        remoteDeviceID = removalScope.remoteDeviceID
    }

    var account: String {
        get throws {
            let digest = try ContactTrustStoreCrypto.hash(
                domain: "KITHRA/CONTACT-TRUST-NAMESPACE/V1\u{0}",
                fields: [
                    relayScopeHash,
                    Data(localUserID.uuidString.lowercased().utf8),
                    Data(localDeviceID.uuidString.lowercased().utf8),
                    Data(remoteUserID.uuidString.lowercased().utf8),
                    Data(remoteDeviceID.uuidString.lowercased().utf8)
                ]
            )
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    func matchesRelationship(_ other: ContactTrustNamespace) -> Bool {
        ContactTrustStoreCrypto.constantTimeEquals(relayScopeHash, other.relayScopeHash) &&
            localUserID == other.localUserID &&
            localDeviceID == other.localDeviceID &&
            remoteUserID == other.remoteUserID
    }

    func containsCandidate(
        local: ContactVerificationIdentity,
        remote: ContactVerificationIdentity
    ) -> Bool {
        ContactTrustStoreCrypto.constantTimeEquals(relayScopeHash, local.relayScopeHash) &&
            ContactTrustStoreCrypto.constantTimeEquals(relayScopeHash, remote.relayScopeHash) &&
            local.userID == localUserID &&
            local.deviceID == localDeviceID &&
            remote.userID == remoteUserID &&
            remote.deviceID == remoteDeviceID
    }

    func containsTrusted(
        local: ContactVerificationIdentity,
        remote: ContactVerificationIdentity
    ) -> Bool {
        // A candidate on a replacement remote device carries the previous trusted
        // identity so the status remains keyChanged until explicit re-verification.
        ContactTrustStoreCrypto.constantTimeEquals(relayScopeHash, local.relayScopeHash) &&
            ContactTrustStoreCrypto.constantTimeEquals(relayScopeHash, remote.relayScopeHash) &&
            local.userID == localUserID &&
            local.deviceID == localDeviceID &&
            remote.userID == remoteUserID
    }
}

private enum ContactTrustStoreCrypto {
    private static let sodium = Sodium()
    private static let digestByteCount = 32

    static func hash(domain: String, fields: [Data]) throws -> Data {
        var message = Data(domain.utf8)
        for field in fields {
            let length = UInt32(field.count)
            message.append(UInt8((length >> 24) & 0xff))
            message.append(UInt8((length >> 16) & 0xff))
            message.append(UInt8((length >> 8) & 0xff))
            message.append(UInt8(length & 0xff))
            message.append(field)
        }

        guard let digest = sodium.genericHash.hash(
            message: Array(message),
            outputLength: digestByteCount
        ) else {
            throw ContactVerificationError.hashingFailed
        }
        return Data(digest)
    }

    static func constantTimeEquals(_ first: Data, _ second: Data) -> Bool {
        sodium.utils.equals(Array(first), Array(second))
    }
}
