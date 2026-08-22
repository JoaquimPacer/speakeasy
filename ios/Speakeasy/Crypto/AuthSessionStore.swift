import Foundation
import Security

private enum ProtectedAuthRecordCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // A numeric reference-date value round-trips Date's Double exactly.
        // ISO8601Encoder drops subsecond precision, which would make the
        // required post-Keychain equality check reject a successful save.
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid protected-session date"
            )
        }
        return decoder
    }
}

struct StoredAuthSession: Codable, Hashable {
    var relayBaseURLString: String
    var session: AuthSession
}

/// Crash-durable authority for a registration attempt. The client-generated
/// device ID and exact local public identity are protected before the first
/// relay request, so a lost response can replay the same registration identity
/// and recover through signed login without creating a second account. This
/// record never leaves the Keychain.
struct PendingRegistrationRecord: Codable, Hashable {
    var relayBaseURLString: String
    var username: String
    var deviceID: UUID
    var deviceName: String?
    var session: AuthSession?
    var expectedIdentity: PendingRegistrationIdentity

    init(
        relayBaseURLString: String,
        username: String,
        deviceID: UUID,
        deviceName: String?,
        session: AuthSession? = nil,
        expectedIdentity: PendingRegistrationIdentity
    ) {
        self.relayBaseURLString = relayBaseURLString
        self.username = username
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.session = session
        self.expectedIdentity = expectedIdentity
    }

    /// Backward-compatible initializer for protected records written by builds
    /// that persisted only after receiving the relay-generated device ID.
    init(
        relayBaseURLString: String,
        username: String,
        session: AuthSession,
        expectedIdentity: PendingRegistrationIdentity
    ) {
        self.init(
            relayBaseURLString: relayBaseURLString,
            username: username,
            deviceID: session.device.id,
            deviceName: session.device.name,
            session: session,
            expectedIdentity: expectedIdentity
        )
    }

    var storedSession: StoredAuthSession? {
        session.map {
            StoredAuthSession(
                relayBaseURLString: relayBaseURLString,
                session: $0
            )
        }
    }

    func completing(with session: AuthSession) -> PendingRegistrationRecord {
        PendingRegistrationRecord(
            relayBaseURLString: relayBaseURLString,
            username: username,
            deviceID: deviceID,
            deviceName: deviceName,
            session: session,
            expectedIdentity: expectedIdentity
        )
    }

    private enum CodingKeys: String, CodingKey {
        case relayBaseURLString
        case username
        case deviceID
        case deviceName
        case session
        case expectedIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relayBaseURLString = try container.decode(String.self, forKey: .relayBaseURLString)
        username = try container.decode(String.self, forKey: .username)
        session = try container.decodeIfPresent(AuthSession.self, forKey: .session)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        expectedIdentity = try container.decode(
            PendingRegistrationIdentity.self,
            forKey: .expectedIdentity
        )
        if let persistedDeviceID = try container.decodeIfPresent(UUID.self, forKey: .deviceID) {
            deviceID = persistedDeviceID
        } else if let session {
            // Older protected records did not encode a top-level device ID,
            // but their completed session carries the exact same authority.
            deviceID = session.device.id
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.deviceID,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "A pending registration intent requires a durable device ID"
                )
            )
        }
        if !container.contains(.deviceName), let session {
            deviceName = session.device.name
        }
    }
}

struct PendingRegistrationIdentity: Codable, Hashable {
    var deviceID: UUID?
    var encryptionPublicKey: Data
    var signingPublicKey: Data

    init(_ identity: DevicePublicIdentity) {
        deviceID = identity.deviceID
        encryptionPublicKey = identity.encryptionPublicKey
        signingPublicKey = identity.signingPublicKey
    }

    var publicIdentityForValidation: DevicePublicIdentity {
        DevicePublicIdentity(
            deviceID: deviceID,
            encryptionPublicKey: encryptionPublicKey,
            signingPublicKey: signingPublicKey,
            // Creation time is not an authentication input. Keeping it out of
            // the durable comparison also avoids date-precision changes during
            // JSON round trips from weakening an otherwise exact key match.
            createdAt: .distantPast
        )
    }
}

enum AuthSessionStoreError: Error, LocalizedError {
    case corruptStoredSession
    case corruptPendingRegistration
    case migrationVerificationFailed
    case persistenceVerificationFailed
    case pendingRegistrationVerificationFailed
    case conflictingRegistrationRecovery
    case ambiguousRegistrationRecovery
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .corruptStoredSession:
            return "The protected relay session could not be decoded. Reload protected storage; Kithra will not erase or replace the existing identity automatically."
        case .corruptPendingRegistration:
            return "The protected pending registration could not be decoded. Reload protected storage; the existing device identity was not replaced."
        case .migrationVerificationFailed:
            return "The legacy relay session was not removed because its protected Keychain copy could not be verified. Reload protected storage before continuing."
        case .persistenceVerificationFailed:
            return "The protected relay session did not match after it was saved to Keychain. The account was not activated locally."
        case .pendingRegistrationVerificationFailed:
            return "The pending relay registration did not match after it was saved to Keychain. Kithra will not rely on it after restart."
        case .conflictingRegistrationRecovery:
            return "Protected registration records disagree. Kithra refused to choose between them or replace the existing identity."
        case .ambiguousRegistrationRecovery:
            return "A relay registration may have completed, but Kithra cannot prove which protected local record is authoritative. Reload protected storage or explicitly reset this device; Kithra will not create replacement keys or another account."
        case .keychain(let status):
            return "Protected session storage failed with Keychain status \(status)."
        }
    }
}

enum ProtectedAuthSessionPersistence {
    static func saveAndVerify(
        _ storedSession: StoredAuthSession,
        in sessionStore: AuthSessionStoring,
        verificationError: AuthSessionStoreError = .persistenceVerificationFailed
    ) throws {
        try sessionStore.save(storedSession)
        guard try sessionStore.load() == storedSession else {
            throw verificationError
        }
    }
}

protocol AuthSessionStoring: AnyObject {
    func load() throws -> StoredAuthSession?
    func save(_ storedSession: StoredAuthSession) throws
    func remove() throws
}

protocol PendingRegistrationStoring: AnyObject {
    func load() throws -> PendingRegistrationRecord?
    func save(_ record: PendingRegistrationRecord) throws
    func remove() throws
}

enum PendingRegistrationPersistence {
    static func saveAndVerify(
        _ record: PendingRegistrationRecord,
        in store: PendingRegistrationStoring
    ) throws {
        try store.save(record)
        guard try store.load() == record else {
            throw AuthSessionStoreError.pendingRegistrationVerificationFailed
        }
    }

    static func removeAndVerify(from store: PendingRegistrationStoring) throws {
        try store.remove()
        guard try store.load() == nil else {
            throw AuthSessionStoreError.pendingRegistrationVerificationFailed
        }
    }
}

enum PendingRegistrationRecovery {
    static func isCompatible(
        _ storedSession: StoredAuthSession,
        with record: PendingRegistrationRecord
    ) -> Bool {
        guard let pendingSession = record.session else {
            return false
        }
        let session = storedSession.session
        return storedSession.relayBaseURLString == record.relayBaseURLString
            && session.user.id == pendingSession.user.id
            && session.user.username == record.username
            && session.device.id == record.deviceID
            && session.device.id == pendingSession.device.id
            && session.device.userID == pendingSession.device.userID
            && AuthSessionValidator.sessionIdentitiesMatch(session, pendingSession)
    }
}

/// Persistent, non-secret state used to distinguish an in-place upgrade from
/// a reinstall whose app Keychain items survived removal of the app container.
///
/// A cleanup marker always wins over every other signal. This prevents a crash
/// after local authority has begun clearing from restoring a surviving bearer
/// session on the next launch.
struct LocalAccountBootstrapPlan: Equatable {
    enum Mode: Equatable {
        case existingInstall
        case legacyUpgrade
        case freshInstall
        case cleanupRecovery
        case registrationRecovery
    }

    let mode: Mode

    var permitsProtectedSessionRestore: Bool {
        mode == .existingInstall || mode == .legacyUpgrade || mode == .registrationRecovery
    }

    var shouldAttemptLegacyMigration: Bool {
        mode == .legacyUpgrade
    }

    var requiresCleanupBeforeIdentityCreation: Bool {
        mode == .freshInstall || mode == .cleanupRecovery
    }

    var requiresVisibleCleanupRetry: Bool {
        mode == .cleanupRecovery
    }

    var requiresRegistrationReconciliation: Bool {
        mode == .registrationRecovery
    }

    static func make(
        hasInstallMarker: Bool,
        cleanupInProgress: Bool,
        cleanupFailed: Bool,
        registrationUncertain: Bool,
        hasLegacySession: Bool
    ) -> LocalAccountBootstrapPlan {
        if cleanupInProgress || cleanupFailed {
            return LocalAccountBootstrapPlan(mode: .cleanupRecovery)
        }
        if registrationUncertain {
            return LocalAccountBootstrapPlan(mode: .registrationRecovery)
        }
        if hasLegacySession {
            return LocalAccountBootstrapPlan(mode: .legacyUpgrade)
        }
        if hasInstallMarker {
            return LocalAccountBootstrapPlan(mode: .existingInstall)
        }
        return LocalAccountBootstrapPlan(mode: .freshInstall)
    }
}

/// UserDefaults contains only lifecycle markers and the non-sensitive relay
/// preference after bootstrap. The legacy session key is removed only after a
/// verified Keychain migration or an explicitly requested local cleanup.
final class LocalAccountBootstrapMarkers {
    enum CleanupStatus: Equatable {
        case inProgress
        case failed
    }

    static let legacySessionKey = "speakeasy.authSession.v1"
    static let installMarkerKey = "speakeasy.installMarker.v1"
    static let cleanupInProgressKey = "speakeasy.localCleanupInProgress.v1"
    static let cleanupFailedKey = "speakeasy.localCleanupFailed.v1"
    static let registrationUncertainKey = "speakeasy.registrationUncertain.v1"

    private let preferences: UserDefaults

    init(preferences: UserDefaults) {
        self.preferences = preferences
    }

    var legacySessionData: Data? {
        preferences.data(forKey: Self.legacySessionKey)
    }

    var cleanupStatus: CleanupStatus? {
        if preferences.bool(forKey: Self.cleanupFailedKey) {
            return .failed
        }
        if preferences.bool(forKey: Self.cleanupInProgressKey) {
            return .inProgress
        }
        return nil
    }

    var hasRegistrationUncertainty: Bool {
        preferences.bool(forKey: Self.registrationUncertainKey)
    }

    var plan: LocalAccountBootstrapPlan {
        LocalAccountBootstrapPlan.make(
            hasInstallMarker: preferences.object(forKey: Self.installMarkerKey) != nil,
            cleanupInProgress: preferences.bool(forKey: Self.cleanupInProgressKey),
            cleanupFailed: preferences.bool(forKey: Self.cleanupFailedKey),
            registrationUncertain: hasRegistrationUncertainty,
            hasLegacySession: legacySessionData != nil
        )
    }

    /// Records that missing install-marker state came from an older installed
    /// app, not an uninstall. Call before removing the only legacy evidence.
    func preserveExistingInstallClassification() {
        preferences.set(true, forKey: Self.installMarkerKey)
    }

    func discardLegacySession() {
        preferences.removeObject(forKey: Self.legacySessionKey)
    }

    /// Must be called before any in-memory or Keychain authority is revoked.
    func beginCleanup() {
        preferences.set(true, forKey: Self.cleanupInProgressKey)
        preferences.removeObject(forKey: Self.cleanupFailedKey)
    }

    /// Keeps cleanup recovery visible after a failed attempt. The failed bit is
    /// written before the in-progress bit is cleared so a crash cannot create a
    /// marker-free window.
    func markCleanupFailed() {
        preferences.set(true, forKey: Self.cleanupFailedKey)
        preferences.removeObject(forKey: Self.cleanupInProgressKey)
    }

    /// Records only that a relay registration response could not be reconciled
    /// with a verified pending record or a verified server rollback. It contains
    /// no username, token, key material, or other account metadata.
    func markRegistrationUncertain() {
        preferences.set(true, forKey: Self.registrationUncertainKey)
    }

    func resolveRegistrationUncertainty() {
        preferences.removeObject(forKey: Self.registrationUncertainKey)
    }

    /// Marks cleanup complete in crash-safe order. If the process stops between
    /// these writes, the still-present cleanup marker forces an idempotent retry.
    func completeCleanup() {
        preferences.set(true, forKey: Self.installMarkerKey)
        preferences.removeObject(forKey: Self.registrationUncertainKey)
        preferences.removeObject(forKey: Self.cleanupInProgressKey)
        preferences.removeObject(forKey: Self.cleanupFailedKey)
    }
}

enum LocalAccountSessionBootstrap {
    static func loadOrMigrate(
        plan: LocalAccountBootstrapPlan,
        legacySessionData: Data?,
        sessionStore: AuthSessionStoring,
        decodeLegacySession: (Data) throws -> StoredAuthSession,
        didVerifyLegacyProtection: (StoredAuthSession) -> Void
    ) throws -> StoredAuthSession? {
        guard plan.permitsProtectedSessionRestore else {
            return nil
        }

        if let protectedSession = try sessionStore.load() {
            if let legacySessionData {
                let legacySession = try decodeLegacySession(legacySessionData)
                guard legacySession == protectedSession else {
                    // Never delete or overwrite either authority when an older
                    // plaintext copy disagrees with the Keychain record. The
                    // caller must surface the conflict for an explicit reset.
                    throw AuthSessionStoreError.migrationVerificationFailed
                }
                // A prior launch may have saved the Keychain item and crashed
                // before deleting UserDefaults. Re-save and read it back before
                // allowing the remaining plaintext bearer copy to be removed.
                try ProtectedAuthSessionPersistence.saveAndVerify(
                    protectedSession,
                    in: sessionStore,
                    verificationError: .migrationVerificationFailed
                )
                didVerifyLegacyProtection(protectedSession)
            }
            return protectedSession
        }
        guard plan.shouldAttemptLegacyMigration,
              let legacySessionData else {
            return nil
        }

        let migratedSession = try decodeLegacySession(legacySessionData)
        try ProtectedAuthSessionPersistence.saveAndVerify(
            migratedSession,
            in: sessionStore,
            verificationError: .migrationVerificationFailed
        )
        didVerifyLegacyProtection(migratedSession)
        return migratedSession
    }
}

/// Stores a just-created relay account independently from the primary session
/// so a process death between server commit, session persistence, and device-ID
/// binding cannot cause a second registration. The accessibility class keeps
/// both the bearer and expected public identity on this device only.
final class KeychainPendingRegistrationStore: PendingRegistrationStoring {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        service: String = "com.speakeasy.auth-session",
        account: String = "pending-registration",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup

        self.encoder = ProtectedAuthRecordCoding.makeEncoder()
        self.decoder = ProtectedAuthRecordCoding.makeDecoder()
    }

    func load() throws -> PendingRegistrationRecord? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AuthSessionStoreError.keychain(status)
        }
        guard let data = item as? Data else {
            throw AuthSessionStoreError.corruptPendingRegistration
        }

        do {
            let record = try decoder.decode(PendingRegistrationRecord.self, from: data)
            try Self.validate(record)
            return record
        } catch let error as AuthSessionStoreError {
            throw error
        } catch {
            throw AuthSessionStoreError.corruptPendingRegistration
        }
    }

    func save(_ record: PendingRegistrationRecord) throws {
        try Self.validate(record)
        let data = try encoder.encode(record)
        var query = baseQuery()
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
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AuthSessionStoreError.keychain(updateStatus)
            }
            return
        }
        throw AuthSessionStoreError.keychain(status)
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthSessionStoreError.keychain(status)
        }
    }

    private static func validate(_ record: PendingRegistrationRecord) throws {
        let zeroDeviceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard let relayURL = URL(string: record.relayBaseURLString),
              relayURL.scheme != nil,
              relayURL.host != nil,
              !record.username.isEmpty,
              record.deviceID != zeroDeviceID,
              record.expectedIdentity.encryptionPublicKey.count == 32,
              record.expectedIdentity.signingPublicKey.count == 32,
              record.expectedIdentity.deviceID == nil
                || record.expectedIdentity.deviceID == record.deviceID else {
            throw AuthSessionStoreError.corruptPendingRegistration
        }
        if let session = record.session {
            guard record.username == session.user.username,
                  !session.bearerToken.isEmpty,
                  session.device.id == record.deviceID,
                  session.device.name == record.deviceName,
                  session.device.userID == session.user.id,
                  AuthSessionValidator.identitiesMatch(
                    record.expectedIdentity.publicIdentityForValidation,
                    session: session
                  ) else {
                throw AuthSessionStoreError.corruptPendingRegistration
            }
        }
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

/// Stores bearer authority in a device-bound Keychain item. The relay URL is
/// duplicated in this record to prevent a token from ever being restored
/// against a different relay; the independently editable relay preference is
/// non-sensitive and remains in UserDefaults.
final class KeychainAuthSessionStore: AuthSessionStoring {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        service: String = "com.speakeasy.auth-session",
        account: String = "primary",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup

        self.encoder = ProtectedAuthRecordCoding.makeEncoder()
        self.decoder = ProtectedAuthRecordCoding.makeDecoder()
    }

    func load() throws -> StoredAuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AuthSessionStoreError.keychain(status)
        }
        guard let data = item as? Data else {
            throw AuthSessionStoreError.corruptStoredSession
        }

        do {
            let storedSession = try decoder.decode(StoredAuthSession.self, from: data)
            try Self.validate(storedSession)
            return storedSession
        } catch let error as AuthSessionStoreError {
            throw error
        } catch {
            throw AuthSessionStoreError.corruptStoredSession
        }
    }

    func save(_ storedSession: StoredAuthSession) throws {
        try Self.validate(storedSession)
        let data = try encoder.encode(storedSession)
        var query = baseQuery()
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
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AuthSessionStoreError.keychain(updateStatus)
            }
            return
        }
        throw AuthSessionStoreError.keychain(status)
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthSessionStoreError.keychain(status)
        }
    }

    private static func validate(_ storedSession: StoredAuthSession) throws {
        guard let relayURL = URL(string: storedSession.relayBaseURLString),
              relayURL.scheme != nil,
              relayURL.host != nil,
              !storedSession.session.bearerToken.isEmpty else {
            throw AuthSessionStoreError.corruptStoredSession
        }
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

enum AuthSessionValidationError: Error, LocalizedError, Equatable {
    case missingOrExpiredSession
    case invalidChallenge
    case identityMismatch
    case noRecoverableSession

    var errorDescription: String? {
        switch self {
        case .missingOrExpiredSession:
            return "The relay returned a missing or already-expired session. Try signing in again."
        case .invalidChallenge:
            return "The relay returned an invalid or expired login challenge. Try again."
        case .identityMismatch:
            return "The relay's login identity does not match this device's protected identity. Local keys were not replaced."
        case .noRecoverableSession:
            return "This relay session cannot be renewed automatically. Reset local registration only if you intend to replace this device identity."
        }
    }
}

enum AuthSessionValidator {
    static let loginChallengeByteCount = 32

    static func validateChallenge(_ challenge: LoginChallenge, now: Date = Date()) throws {
        guard challenge.challenge.count == loginChallengeByteCount,
              challenge.expiresAt > now else {
            throw AuthSessionValidationError.invalidChallenge
        }
    }

    static func validateRegistration(
        _ session: AuthSession,
        requestedUsername: String,
        localIdentity: DevicePublicIdentity,
        now: Date = Date()
    ) throws {
        try validateSessionAuthority(session, now: now)
        guard session.user.username == requestedUsername,
              session.device.userID == session.user.id,
              localIdentity.deviceID == nil || localIdentity.deviceID == session.device.id,
              constantTimeEquals(localIdentity.encryptionPublicKey, session.device.encryptionPublicKey),
              constantTimeEquals(localIdentity.signingPublicKey, session.device.signingPublicKey) else {
            throw AuthSessionValidationError.identityMismatch
        }
    }

    /// Validates an expired or pre-expiry-field session only as a recovery
    /// claim. Callers must still obtain a successful authenticated relay
    /// response (using the bearer or a signed challenge renewal) before
    /// publishing authenticated UI state.
    static func validateStoredRecoveryAuthority(
        _ session: AuthSession,
        requestedUsername: String,
        localIdentity: DevicePublicIdentity
    ) throws {
        guard !session.bearerToken.isEmpty,
              session.user.username == requestedUsername,
              session.device.userID == session.user.id,
              localIdentity.deviceID == nil || localIdentity.deviceID == session.device.id,
              identitiesMatch(localIdentity, session: session) else {
            throw AuthSessionValidationError.identityMismatch
        }
    }

    static func validateRenewal(
        _ session: AuthSession,
        replacing previousSession: AuthSession,
        localIdentity: DevicePublicIdentity,
        allowsUnboundLocalIdentity: Bool = false,
        now: Date = Date()
    ) throws {
        try validateSessionAuthority(session, now: now)
        guard session.user.id == previousSession.user.id,
              session.user.username == previousSession.user.username,
              session.device.id == previousSession.device.id,
              session.device.userID == previousSession.device.userID,
              session.device.userID == session.user.id,
              (localIdentity.deviceID == session.device.id
                || (allowsUnboundLocalIdentity && localIdentity.deviceID == nil)),
              constantTimeEquals(localIdentity.encryptionPublicKey, session.device.encryptionPublicKey),
              constantTimeEquals(localIdentity.signingPublicKey, session.device.signingPublicKey),
              constantTimeEquals(previousSession.device.encryptionPublicKey, session.device.encryptionPublicKey),
              constantTimeEquals(previousSession.device.signingPublicKey, session.device.signingPublicKey) else {
            throw AuthSessionValidationError.identityMismatch
        }
    }

    static func validateLocalIdentity(
        _ identity: DevicePublicIdentity,
        against session: AuthSession
    ) throws {
        guard session.device.userID == session.user.id,
              identity.deviceID == session.device.id,
              constantTimeEquals(identity.encryptionPublicKey, session.device.encryptionPublicKey),
              constantTimeEquals(identity.signingPublicKey, session.device.signingPublicKey) else {
            throw AuthSessionValidationError.identityMismatch
        }
    }

    static func identitiesMatch(
        _ identity: DevicePublicIdentity,
        session: AuthSession
    ) -> Bool {
        constantTimeEquals(identity.encryptionPublicKey, session.device.encryptionPublicKey)
            && constantTimeEquals(identity.signingPublicKey, session.device.signingPublicKey)
    }

    static func sessionIdentitiesMatch(_ first: AuthSession, _ second: AuthSession) -> Bool {
        constantTimeEquals(
            first.device.encryptionPublicKey,
            second.device.encryptionPublicKey
        ) && constantTimeEquals(
            first.device.signingPublicKey,
            second.device.signingPublicKey
        )
    }

    private static func validateSessionAuthority(_ session: AuthSession, now: Date) throws {
        guard !session.bearerToken.isEmpty,
              let expiresAt = session.expiresAt,
              expiresAt > now else {
            throw AuthSessionValidationError.missingOrExpiredSession
        }
    }

    private static func constantTimeEquals(_ first: Data, _ second: Data) -> Bool {
        guard first.count == second.count else {
            return false
        }
        var difference: UInt8 = 0
        for (left, right) in zip(first, second) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

enum RelayURLPolicy {
    static var allowsLocalDevelopmentHTTP: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func allows(_ url: URL, localDevelopmentHTTP: Bool = allowsLocalDevelopmentHTTP) -> Bool {
        guard url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        if scheme == "https" {
            return true
        }
        guard localDevelopmentHTTP, scheme == "http" else {
            return false
        }
        return isLocalDevelopmentHost(host)
    }

    private static func isLocalDevelopmentHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".localhost") {
            return true
        }

        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else {
            return false
        }
        if octets[0] == 127 || octets[0] == 10 {
            return true
        }
        if octets[0] == 192, octets[1] == 168 {
            return true
        }
        return octets[0] == 172 && (16...31).contains(octets[1])
    }
}
