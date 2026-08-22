import AVFoundation
import Foundation
import Security
import XCTest
@testable import Kithra

final class AuthenticationTests: XCTestCase {
    override func tearDown() {
        AuthenticationURLProtocol.handler = nil
        super.tearDown()
    }

    func testKeychainSessionStoreRoundTripsWithThisDeviceOnlyAccessibility() throws {
        let service = "com.speakeasy.auth-session.tests.\(UUID().uuidString)"
        let account = "primary"
        let store = KeychainAuthSessionStore(service: service, account: account)
        defer { try? store.remove() }

        let storedSession = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: makeSession(token: "protected-token")
        )
        try store.save(storedSession)
        XCTAssertEqual(try store.load(), storedSession)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )

        try store.remove()
        XCTAssertNil(try store.load())
    }

    func testPendingRegistrationStoreRoundTripsWithThisDeviceOnlyAccessibility() throws {
        let service = "com.speakeasy.auth-session.tests.\(UUID().uuidString)"
        let account = "pending-registration"
        let store = KeychainPendingRegistrationStore(service: service, account: account)
        defer { try? store.remove() }

        let session = makeSession(token: "pending-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let record = PendingRegistrationRecord(
            relayBaseURLString: "https://relay.example.test",
            username: session.user.username,
            session: session,
            expectedIdentity: PendingRegistrationIdentity(identity)
        )
        try PendingRegistrationPersistence.saveAndVerify(record, in: store)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )

        try PendingRegistrationPersistence.removeAndVerify(from: store)
    }

    func testLegacySessionWithoutInstallMarkerIsRecoverableUpgrade() throws {
        let suiteName = "KithraBootstrapTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let legacySession = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: makeSession(token: "legacy-token")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        preferences.set(
            try encoder.encode(legacySession),
            forKey: LocalAccountBootstrapMarkers.legacySessionKey
        )

        let markers = LocalAccountBootstrapMarkers(preferences: preferences)
        XCTAssertEqual(markers.plan.mode, .legacyUpgrade)
        XCTAssertFalse(markers.plan.requiresCleanupBeforeIdentityCreation)

        let store = InMemoryAuthSessionStore()
        let restoredSession = try LocalAccountSessionBootstrap.loadOrMigrate(
            plan: markers.plan,
            legacySessionData: markers.legacySessionData,
            sessionStore: store,
            decodeLegacySession: { data in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(StoredAuthSession.self, from: data)
            }
        ) { verifiedSession in
            XCTAssertTrue(store.didVerifySavedValue)
            markers.preserveExistingInstallClassification()
            markers.discardLegacySession()
            XCTAssertEqual(verifiedSession, legacySession)
        }

        XCTAssertEqual(restoredSession, legacySession)
        XCTAssertEqual(store.storedSession, legacySession)
        XCTAssertNil(markers.legacySessionData)
        XCTAssertEqual(markers.plan.mode, .existingInstall)
    }

    func testLegacySessionSurvivesFailedKeychainSave() throws {
        let suiteName = "KithraBootstrapTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let legacySession = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: makeSession(token: "legacy-token")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode(legacySession)
        preferences.set(legacyData, forKey: LocalAccountBootstrapMarkers.legacySessionKey)
        let markers = LocalAccountBootstrapMarkers(preferences: preferences)
        let store = InMemoryAuthSessionStore(saveError: AuthenticationTestError.saveFailed)
        var didVerifyMigration = false

        XCTAssertThrowsError(try LocalAccountSessionBootstrap.loadOrMigrate(
            plan: markers.plan,
            legacySessionData: markers.legacySessionData,
            sessionStore: store,
            decodeLegacySession: { data in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(StoredAuthSession.self, from: data)
            },
            didVerifyLegacyProtection: { _ in didVerifyMigration = true }
        ))

        XCTAssertFalse(didVerifyMigration)
        XCTAssertEqual(markers.legacySessionData, legacyData)
        XCTAssertEqual(markers.plan.mode, .legacyUpgrade)
    }

    func testLegacySessionSurvivesKeychainReadbackMismatch() throws {
        let suiteName = "KithraBootstrapTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let legacySession = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: makeSession(token: "legacy-token")
        )
        let mismatchedSession = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: makeSession(token: "different-token")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode(legacySession)
        preferences.set(legacyData, forKey: LocalAccountBootstrapMarkers.legacySessionKey)
        let markers = LocalAccountBootstrapMarkers(preferences: preferences)
        let store = InMemoryAuthSessionStore(postSaveReadback: mismatchedSession)
        var didVerifyMigration = false

        XCTAssertThrowsError(try LocalAccountSessionBootstrap.loadOrMigrate(
            plan: markers.plan,
            legacySessionData: markers.legacySessionData,
            sessionStore: store,
            decodeLegacySession: { data in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(StoredAuthSession.self, from: data)
            },
            didVerifyLegacyProtection: { _ in didVerifyMigration = true }
        )) { error in
            guard case AuthSessionStoreError.migrationVerificationFailed = error else {
                return XCTFail("Expected migration verification failure, got \(error)")
            }
        }

        XCTAssertFalse(didVerifyMigration)
        XCTAssertEqual(markers.legacySessionData, legacyData)
        XCTAssertEqual(markers.plan.mode, .legacyUpgrade)
    }

    func testExistingProtectedSessionNeverDeletesDifferentLegacyBearer() throws {
        let protectedSession = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: makeSession(token: "protected-token")
        )
        let legacySession = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: makeSession(token: "different-legacy-token")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode(legacySession)
        let store = InMemoryAuthSessionStore(storedSession: protectedSession)
        var didVerifyProtection = false

        XCTAssertThrowsError(try LocalAccountSessionBootstrap.loadOrMigrate(
            plan: LocalAccountBootstrapPlan(mode: .legacyUpgrade),
            legacySessionData: legacyData,
            sessionStore: store,
            decodeLegacySession: { data in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(StoredAuthSession.self, from: data)
            },
            didVerifyLegacyProtection: { _ in didVerifyProtection = true }
        )) { error in
            guard case AuthSessionStoreError.migrationVerificationFailed = error else {
                return XCTFail("Expected migration conflict, got \(error)")
            }
        }

        XCTAssertFalse(didVerifyProtection)
        XCTAssertEqual(store.storedSession, protectedSession)
    }

    func testCleanupFailureMarkerSurvivesRestartAndWinsOverLegacyRestore() throws {
        let suiteName = "KithraBootstrapTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }

        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        preferences.set(Data([0x01]), forKey: LocalAccountBootstrapMarkers.legacySessionKey)
        let markers = LocalAccountBootstrapMarkers(preferences: preferences)

        markers.beginCleanup()
        XCTAssertEqual(markers.cleanupStatus, .inProgress)
        XCTAssertEqual(markers.plan.mode, .cleanupRecovery)

        markers.markCleanupFailed()
        let relaunchedMarkers = LocalAccountBootstrapMarkers(preferences: preferences)
        XCTAssertEqual(relaunchedMarkers.cleanupStatus, .failed)
        XCTAssertEqual(relaunchedMarkers.plan.mode, .cleanupRecovery)
        XCTAssertTrue(relaunchedMarkers.plan.requiresCleanupBeforeIdentityCreation)
        XCTAssertTrue(relaunchedMarkers.plan.requiresVisibleCleanupRetry)

        relaunchedMarkers.discardLegacySession()
        relaunchedMarkers.completeCleanup()
        XCTAssertNil(relaunchedMarkers.cleanupStatus)
        XCTAssertEqual(relaunchedMarkers.plan.mode, .existingInstall)
    }

    @MainActor
    func testRegistrationPersistsBeforeBindingAndRetriesWithoutSecondRelayAccount() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let deviceID = UUID()
        let session = makeSession(deviceID: deviceID, token: "registered-token")
        let encoder = wireEncoder()
        var registrationCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                registrationCount += 1
                return (200, try encoder.encode(session))
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }

        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let keyManager = RegistrationRecoveryKeyManager(
            identity: identity,
            bindFailuresRemaining: 1
        )
        let sessionStore = InMemoryAuthSessionStore()
        let pendingStore = InMemoryPendingRegistrationStore()
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        await state.register(username: "alice")
        XCTAssertNil(state.currentUser)
        XCTAssertEqual(registrationCount, 1)
        XCTAssertEqual(keyManager.bindCallCount, 1)
        XCTAssertNotNil(pendingStore.record)
        XCTAssertEqual(
            sessionStore.storedSession,
            StoredAuthSession(
                relayBaseURLString: "https://relay.example.test",
                session: session
            )
        )

        await state.register(username: "alice")
        XCTAssertEqual(registrationCount, 1, "Recovery must not create a second relay account")
        XCTAssertEqual(keyManager.bindCallCount, 2)
        XCTAssertEqual(state.currentUser, session.user)
        XCTAssertEqual(state.deviceIdentity?.deviceID, deviceID)
        XCTAssertNil(pendingStore.record)
    }

    @MainActor
    func testPrimarySessionFailureKeepsDurablePendingWithoutRollback() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(deviceID: UUID(), token: "rollback-token")
        let encoder = wireEncoder()
        var registrationCount = 0
        var deletionAuthorization: String?
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                registrationCount += 1
                return (200, try encoder.encode(session))
            case "/account":
                deletionAuthorization = request.value(forHTTPHeaderField: "Authorization")
                return (204, Data())
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }

        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(
            saveError: AuthenticationTestError.saveFailed
        )
        let pendingStore = InMemoryPendingRegistrationStore()
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        await state.register(username: "alice")
        XCTAssertNil(state.currentUser)
        XCTAssertEqual(registrationCount, 1)
        XCTAssertNil(deletionAuthorization)
        XCTAssertEqual(keyManager.bindCallCount, 0)
        XCTAssertEqual(pendingStore.record?.session, session)

        sessionStore.saveError = nil
        await state.register(username: "alice")
        XCTAssertEqual(registrationCount, 1, "Durable recovery must not create a second relay account")
        XCTAssertEqual(keyManager.bindCallCount, 1)
        XCTAssertEqual(state.currentUser, session.user)
        XCTAssertNil(pendingStore.record)
    }

    @MainActor
    func testPendingRegistrationPersistenceFailureRollsBackBeforeRetry() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(deviceID: UUID(), token: "rollback-token")
        let encoder = wireEncoder()
        var registrationCount = 0
        var deletionAuthorization: String?
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                registrationCount += 1
                return (200, try encoder.encode(session))
            case "/account":
                deletionAuthorization = request.value(forHTTPHeaderField: "Authorization")
                return (204, Data())
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }

        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore()
        let pendingStore = InMemoryPendingRegistrationStore(
            saveError: AuthenticationTestError.saveFailed
        )
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        await state.register(username: "alice")
        XCTAssertNil(state.currentUser)
        XCTAssertEqual(registrationCount, 1)
        XCTAssertEqual(deletionAuthorization, "Bearer rollback-token")
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(pendingStore.record)

        pendingStore.saveError = nil
        await state.register(username: "alice")
        XCTAssertEqual(registrationCount, 2, "A verified rollback permits one clean retry")
        XCTAssertEqual(state.currentUser, session.user)
    }

    @MainActor
    func testPendingRegistrationRecoversAcrossRestartWithoutSecondRegistration() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let deviceID = UUID()
        let session = makeSession(deviceID: deviceID, token: "pending-token")
        let unboundIdentity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let pendingRecord = PendingRegistrationRecord(
            relayBaseURLString: "https://relay.example.test",
            username: "alice",
            session: session,
            expectedIdentity: PendingRegistrationIdentity(unboundIdentity)
        )
        let pendingStore = InMemoryPendingRegistrationStore(record: pendingRecord)
        let sessionStore = InMemoryAuthSessionStore()
        let keyManager = RegistrationRecoveryKeyManager(identity: unboundIdentity)
        var registrationCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                registrationCount += 1
                return (500, Data())
            case "/contacts", "/messages":
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer pending-token"
                )
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }

        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        try await waitUntil { state.currentUser != nil }
        XCTAssertEqual(registrationCount, 0)
        XCTAssertEqual(state.currentUser, session.user)
        XCTAssertEqual(state.deviceIdentity?.deviceID, deviceID)
        XCTAssertEqual(sessionStore.storedSession, pendingRecord.storedSession)
        XCTAssertNil(pendingStore.record)
    }

    @MainActor
    func testTransientPendingBindingFailureIsRetryableAndBlocksRelaySwitch() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(deviceID: UUID(), token: "pending-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let pendingRecord = PendingRegistrationRecord(
            relayBaseURLString: "https://relay.example.test",
            username: "alice",
            session: session,
            expectedIdentity: PendingRegistrationIdentity(identity)
        )
        let pendingStore = InMemoryPendingRegistrationStore(record: pendingRecord)
        let keyManager = RegistrationRecoveryKeyManager(
            identity: identity,
            bindFailuresRemaining: 1
        )
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: InMemoryAuthSessionStore(),
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        try await waitUntil { state.needsAuthenticationRecoveryRetry }
        XCTAssertFalse(state.needsLocalCleanupRetry)
        XCTAssertNotNil(pendingStore.record)
        await state.updateRelayBaseURL("https://other-relay.example.test")
        XCTAssertEqual(state.relayBaseURLString, "https://relay.example.test")

        await state.retryAuthenticationRecovery()
        XCTAssertEqual(state.currentUser, session.user)
        XCTAssertFalse(state.needsAuthenticationRecoveryRetry)
        XCTAssertNil(pendingStore.record)
    }

    @MainActor
    func testExpiredStoredSessionRenewsBeforeRestorePublishesUser() async throws {
        let suiteName = "KithraRestoreTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let deviceID = UUID()
        let expired = makeSession(
            deviceID: deviceID,
            token: "expired-token",
            expiresAt: Date().addingTimeInterval(-60)
        )
        let renewed = makeSession(deviceID: deviceID, token: "renewed-token")
        let stored = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: expired
        )
        let sessionStore = InMemoryAuthSessionStore(storedSession: stored)
        let identity = DevicePublicIdentity(
            deviceID: deviceID,
            encryptionPublicKey: expired.device.encryptionPublicKey,
            signingPublicKey: expired.device.signingPublicKey,
            createdAt: expired.device.createdAt
        )
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let encoder = wireEncoder()
        let challenge = LoginChallenge(
            challengeID: UUID(),
            challenge: Data(repeating: 0x42, count: 32),
            expiresAt: Date().addingTimeInterval(60)
        )
        var protectedRequestTokens: [String?] = []
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/challenge":
                return (200, try encoder.encode(challenge))
            case "/auth/login":
                return (200, try encoder.encode(renewed))
            case "/contacts", "/messages":
                protectedRequestTokens.append(
                    request.value(forHTTPHeaderField: "Authorization")
                )
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }

        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: InMemoryPendingRegistrationStore(),
            preferences: preferences,
            seedPreviewData: false
        )

        try await waitUntil { state.currentUser != nil }
        XCTAssertEqual(state.currentUser, renewed.user)
        XCTAssertEqual(
            sessionStore.storedSession,
            StoredAuthSession(
                relayBaseURLString: "https://relay.example.test",
                session: renewed
            )
        )
        XCTAssertFalse(protectedRequestTokens.contains("Bearer expired-token"))
        XCTAssertTrue(protectedRequestTokens.allSatisfy { $0 == "Bearer renewed-token" })
    }

    @MainActor
    func testRenewalReadbackMismatchNeverPublishesAuthenticatedState() async throws {
        let suiteName = "KithraRestoreTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let deviceID = UUID()
        let expired = makeSession(
            deviceID: deviceID,
            token: "expired-token",
            expiresAt: Date().addingTimeInterval(-60)
        )
        let renewed = makeSession(deviceID: deviceID, token: "renewed-token")
        let mismatched = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: makeSession(deviceID: deviceID, token: "wrong-readback-token")
        )
        let sessionStore = InMemoryAuthSessionStore(
            storedSession: StoredAuthSession(
                relayBaseURLString: "https://relay.example.test",
                session: expired
            ),
            postSaveReadback: mismatched
        )
        let identity = DevicePublicIdentity(
            deviceID: deviceID,
            encryptionPublicKey: expired.device.encryptionPublicKey,
            signingPublicKey: expired.device.signingPublicKey,
            createdAt: expired.device.createdAt
        )
        let encoder = wireEncoder()
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/challenge":
                return (200, try encoder.encode(LoginChallenge(
                    challengeID: UUID(),
                    challenge: Data(repeating: 0x42, count: 32),
                    expiresAt: Date().addingTimeInterval(60)
                )))
            case "/auth/login":
                return (200, try encoder.encode(renewed))
            case "/contacts", "/messages":
                XCTFail("No protected request may use an unverified renewed Keychain write")
                return (500, Data())
            default:
                return (404, Data())
            }
        }

        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: RegistrationRecoveryKeyManager(identity: identity),
            sessionStore: sessionStore,
            pendingRegistrationStore: InMemoryPendingRegistrationStore(),
            preferences: preferences,
            seedPreviewData: false
        )

        try await waitUntil { state.needsAuthenticationRecoveryRetry }
        XCTAssertNil(state.currentUser)
        XCTAssertNil(state.deviceIdentity)
        XCTAssertFalse(state.needsLocalCleanupRetry)
    }

    @MainActor
    func testLegacyNilExpiryBearerMustAuthenticateBeforeRestorePublishesUser() async throws {
        let suiteName = "KithraRestoreTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let deviceID = UUID()
        var legacy = makeSession(deviceID: deviceID, token: "legacy-token")
        legacy.expiresAt = nil
        let identity = DevicePublicIdentity(
            deviceID: deviceID,
            encryptionPublicKey: legacy.device.encryptionPublicKey,
            signingPublicKey: legacy.device.signingPublicKey,
            createdAt: legacy.device.createdAt
        )
        var challengeCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/challenge", "/auth/login":
                challengeCount += 1
                return (500, Data())
            case "/contacts", "/messages":
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer legacy-token"
                )
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }

        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: RegistrationRecoveryKeyManager(identity: identity),
            sessionStore: InMemoryAuthSessionStore(storedSession: StoredAuthSession(
                relayBaseURLString: "https://relay.example.test",
                session: legacy
            )),
            pendingRegistrationStore: InMemoryPendingRegistrationStore(),
            preferences: preferences,
            seedPreviewData: false
        )

        try await waitUntil { state.currentUser != nil }
        XCTAssertEqual(state.currentUser, legacy.user)
        XCTAssertEqual(challengeCount, 0)
    }

    @MainActor
    func testConcurrentRegisterCallsShareOneFlightAndOneRelayRequest() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(deviceID: UUID(), token: "one-flight-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let gate = RegistrationRequestGate()
        let encoder = wireEncoder()
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                gate.recordRequestAndWait()
                return (200, try encoder.encode(session))
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: RegistrationRecoveryKeyManager(identity: identity),
            sessionStore: InMemoryAuthSessionStore(),
            pendingRegistrationStore: InMemoryPendingRegistrationStore(),
            preferences: preferences,
            seedPreviewData: false
        )

        let first = Task { await state.register(username: "alice") }
        try await waitUntil { gate.requestCount == 1 }
        let second = Task { await state.register(username: "alice") }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(gate.requestCount, 1)
        XCTAssertTrue(state.isRegistrationInFlight)

        gate.open()
        await first.value
        await second.value
        XCTAssertEqual(gate.requestCount, 1)
        XCTAssertFalse(state.isRegistrationInFlight)
        XCTAssertEqual(state.currentUser, session.user)
    }

    @MainActor
    func testPostAuthenticationRefreshFailureKeepsSetupFailClosedUntilRecoveryCompletes() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(deviceID: UUID(), token: "refresh-recovery-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let sessionStore = InMemoryAuthSessionStore()
        let pendingStore = InMemoryPendingRegistrationStore()
        let encoder = wireEncoder()
        var registrationCount = 0
        var shouldFailMessagesRefresh = true
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                registrationCount += 1
                return (200, try encoder.encode(session))
            case "/contacts":
                return (200, Data("[]".utf8))
            case "/messages":
                if shouldFailMessagesRefresh {
                    return (500, Data("refresh failed".utf8))
                }
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: RegistrationRecoveryKeyManager(identity: identity),
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        await state.register(username: "alice")
        XCTAssertNil(state.currentUser, "Signed-in UI must remain hidden until refresh and pending cleanup finish")
        XCTAssertNil(state.deviceIdentity)
        XCTAssertTrue(state.needsAuthenticationRecoveryRetry)
        XCTAssertTrue(state.isAuthenticationBootstrapUncertain)
        XCTAssertNotNil(pendingStore.record)

        shouldFailMessagesRefresh = false
        await state.retryAuthenticationRecovery()
        XCTAssertEqual(registrationCount, 1, "Recovery must not create a second relay account")
        XCTAssertEqual(state.currentUser, session.user)
        XCTAssertFalse(state.needsAuthenticationRecoveryRetry)
        XCTAssertNil(pendingStore.record)
    }

    @MainActor
    func testTransientSessionLoadBlocksSetupAndReloadsBothStoresWithoutErasing() async throws {
        let suiteName = "KithraBootstrapTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let sessionStore = InMemoryAuthSessionStore(
            loadError: AuthSessionStoreError.keychain(errSecInteractionNotAllowed)
        )
        let pendingStore = InMemoryPendingRegistrationStore()
        let session = makeSession(token: "unused-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        XCTAssertTrue(state.needsAuthenticationStorageReload)
        XCTAssertTrue(state.isSetupMutationBlocked)
        XCTAssertFalse(state.needsLocalCleanupRetry)
        XCTAssertEqual(sessionStore.loadCallCount, 1)
        XCTAssertEqual(pendingStore.loadCallCount, 1, "Bootstrap must inspect both protected namespaces")

        await state.prepareLocalIdentity()
        XCTAssertEqual(keyManager.loadOrCreateCallCount, 0)
        await state.updateRelayBaseURL("https://other-relay.example.test")
        XCTAssertEqual(state.relayBaseURLString, "https://relay.example.test")

        sessionStore.loadError = nil
        await state.retryAuthenticationStorageLoad()
        XCTAssertFalse(state.needsAuthenticationStorageReload)
        XCTAssertFalse(state.isAuthenticationBootstrapUncertain)
        XCTAssertGreaterThanOrEqual(sessionStore.loadCallCount, 2)
        XCTAssertGreaterThanOrEqual(pendingStore.loadCallCount, 2)
        XCTAssertEqual(sessionStore.removeCallCount, 0)
        XCTAssertEqual(pendingStore.removeCallCount, 0)
        XCTAssertEqual(keyManager.removeCallCount, 0)
    }

    @MainActor
    func testCorruptPendingLoadBlocksPrimaryUntilNonDestructiveReconcile() async throws {
        let suiteName = "KithraBootstrapTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(deviceID: UUID(), token: "protected-token")
        let stored = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        )
        let identity = DevicePublicIdentity(
            deviceID: session.device.id,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let sessionStore = InMemoryAuthSessionStore(storedSession: stored)
        let pendingStore = InMemoryPendingRegistrationStore(
            loadError: AuthSessionStoreError.corruptPendingRegistration
        )
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: RegistrationRecoveryKeyManager(identity: identity),
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        XCTAssertTrue(state.needsAuthenticationStorageReload)
        XCTAssertNil(state.currentUser, "Primary authority must not win while pending storage is unreadable")
        pendingStore.loadError = nil
        await state.retryAuthenticationStorageLoad()
        XCTAssertEqual(state.currentUser, session.user)
        XCTAssertFalse(state.needsAuthenticationStorageReload)
        XCTAssertEqual(sessionStore.removeCallCount, 0)
        XCTAssertEqual(pendingStore.removeCallCount, 0)
    }

    @MainActor
    func testAmbiguousPersistenceAndRollbackFailureSurvivesRelaunchBlocked() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(deviceID: UUID(), token: "ambiguous-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let sessionStore = InMemoryAuthSessionStore()
        let pendingStore = InMemoryPendingRegistrationStore(
            saveError: AuthenticationTestError.saveFailed
        )
        let encoder = wireEncoder()
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                return (200, try encoder.encode(session))
            case "/account":
                return (500, Data("rollback failed".utf8))
            default:
                return (404, Data())
            }
        }
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let firstLaunch = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        await firstLaunch.register(username: "alice")
        let markers = LocalAccountBootstrapMarkers(preferences: preferences)
        XCTAssertTrue(markers.hasRegistrationUncertainty)
        XCTAssertTrue(firstLaunch.needsAuthenticationRecoveryRetry)

        let relaunched = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )
        XCTAssertTrue(relaunched.needsAuthenticationStorageReload)
        XCTAssertTrue(relaunched.isSetupMutationBlocked)
        XCTAssertNil(relaunched.currentUser)
        await relaunched.prepareLocalIdentity()
        XCTAssertEqual(keyManager.loadOrCreateCallCount, 1, "Only the first registration may load existing keys")
        XCTAssertEqual(sessionStore.removeCallCount, 0)
        XCTAssertEqual(pendingStore.removeCallCount, 0)
        XCTAssertTrue(markers.hasRegistrationUncertainty)
    }

    @MainActor
    func testCompatiblePendingRecoveryClearsDurableUncertaintyOnlyAfterActivation() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let markers = LocalAccountBootstrapMarkers(preferences: preferences)
        markers.markRegistrationUncertain()

        let session = makeSession(deviceID: UUID(), token: "recoverable-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let record = PendingRegistrationRecord(
            relayBaseURLString: "https://relay.example.test",
            username: "alice",
            session: session,
            expectedIdentity: PendingRegistrationIdentity(identity)
        )
        let pendingStore = InMemoryPendingRegistrationStore(record: record)
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: RegistrationRecoveryKeyManager(identity: identity),
            sessionStore: InMemoryAuthSessionStore(),
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        XCTAssertTrue(markers.hasRegistrationUncertainty)
        try await waitUntil {
            state.currentUser != nil && !state.isAuthenticationBootstrapUncertain
        }
        XCTAssertFalse(markers.hasRegistrationUncertainty)
        XCTAssertNil(pendingStore.record)
        XCTAssertFalse(state.isAuthenticationBootstrapUncertain)
    }

    @MainActor
    func testConflictingRecordsRemainBlockedUntilExplicitConfirmedReset() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let markers = LocalAccountBootstrapMarkers(preferences: preferences)
        markers.markRegistrationUncertain()

        let primary = makeSession(deviceID: UUID(), token: "primary-token")
        let conflicting = makeSession(deviceID: UUID(), token: "pending-token")
        let pendingIdentity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: conflicting.device.encryptionPublicKey,
            signingPublicKey: conflicting.device.signingPublicKey,
            createdAt: conflicting.device.createdAt
        )
        let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: primary
        ))
        let pendingStore = InMemoryPendingRegistrationStore(record: PendingRegistrationRecord(
            relayBaseURLString: "https://relay.example.test",
            username: "alice",
            session: conflicting,
            expectedIdentity: PendingRegistrationIdentity(pendingIdentity)
        ))
        let keyManager = RegistrationRecoveryKeyManager(identity: pendingIdentity)
        let mediaRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KithraAuthResetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            mediaPipeline: DefaultMediaPipeline(
                keyManager: keyManager,
                tempRoot: mediaRoot.appendingPathComponent("tmp", isDirectory: true),
                localMediaRoot: mediaRoot.appendingPathComponent("local", isDirectory: true)
            ),
            contactTrustStore: KeychainContactTrustStore(
                service: "com.speakeasy.auth-reset.tests.\(UUID().uuidString)"
            ),
            messageReplayStore: KeychainMessageReplayStore(
                service: "com.speakeasy.auth-reset.tests.\(UUID().uuidString)"
            ),
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            preferences: preferences,
            seedPreviewData: false
        )

        XCTAssertTrue(state.needsAuthenticationStorageReload)
        await state.retryAuthenticationStorageLoad()
        XCTAssertTrue(state.needsAuthenticationStorageReload, "Reload must not choose between conflicting records")
        XCTAssertEqual(sessionStore.removeCallCount, 0)
        XCTAssertEqual(pendingStore.removeCallCount, 0)

        await state.resetLocalRegistration(confirmation: .eraseProtectedLocalAccount)
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(pendingStore.record)
        XCTAssertNil(keyManager.identity)
        XCTAssertFalse(state.needsAuthenticationStorageReload)
        XCTAssertFalse(state.needsLocalCleanupRetry)
        XCTAssertFalse(markers.hasRegistrationUncertainty)
        XCTAssertNil(markers.cleanupStatus)
    }

    func testSwiftSodiumLoginSignatureMatchesSharedGoVector() throws {
        let signingPrivateKey = try XCTUnwrap(Data(
            base64Encoded: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8DoQe/884Qvh1w3RjnS8CZZ+TWMJulDV8d3IZkElUxuA=="
        ))
        let challenge = try XCTUnwrap(Data(
            base64Encoded: "oKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr8="
        ))
        let expectedSignature = try XCTUnwrap(Data(
            base64Encoded: "poTjVxqtYqlw+YyUnXijeLbYyvPu6JN8SKGVJjPXX8obqhANaB3gh0dNT/tC2xzVWkBA6bGS4mZ/nwRcUvfJAg=="
        ))

        let signature = try KeychainDeviceKeyManager.loginChallengeResponse(
            challenge: challenge,
            signingPrivateKey: signingPrivateKey
        )
        XCTAssertEqual(signature, expectedSignature)
    }

    func testRelayURLPolicyRequiresHTTPSOutsideNarrowDebugLocalException() throws {
        XCTAssertTrue(RelayURLPolicy.allows(try XCTUnwrap(URL(string: "https://relay.example.test")), localDevelopmentHTTP: false))
        XCTAssertFalse(RelayURLPolicy.allows(try XCTUnwrap(URL(string: "http://relay.example.test")), localDevelopmentHTTP: false))
        XCTAssertTrue(RelayURLPolicy.allows(try XCTUnwrap(URL(string: "http://localhost:8080")), localDevelopmentHTTP: true))
        XCTAssertTrue(RelayURLPolicy.allows(try XCTUnwrap(URL(string: "http://192.168.1.20:8080")), localDevelopmentHTTP: true))
        XCTAssertFalse(RelayURLPolicy.allows(try XCTUnwrap(URL(string: "http://example.com")), localDevelopmentHTTP: true))
        XCTAssertFalse(RelayURLPolicy.allows(try XCTUnwrap(URL(string: "https://user:secret@example.com")), localDevelopmentHTTP: true))
    }

    func testEncryptedMediaUploadPolicyRequiresExactNonemptyFileWithinLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KithraUploadPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let blobURL = directory.appendingPathComponent("ciphertext.blob")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: blobURL)
        XCTAssertEqual(
            try EncryptedMediaUploadPolicy.validate(
                fileURL: blobURL,
                declaredBlobSize: 4,
                maximumBytes: 4
            ),
            4
        )

        XCTAssertThrowsError(try EncryptedMediaUploadPolicy.validate(
            fileURL: blobURL,
            declaredBlobSize: 3,
            maximumBytes: 4
        )) { error in
            XCTAssertEqual(
                error as? EncryptedMediaUploadPolicyError,
                .declaredSizeMismatch(declared: 3, actual: 4)
            )
        }
        XCTAssertThrowsError(try EncryptedMediaUploadPolicy.validate(
            fileURL: blobURL,
            declaredBlobSize: 4,
            maximumBytes: 3
        )) { error in
            XCTAssertEqual(
                error as? EncryptedMediaUploadPolicyError,
                .blobTooLarge(actual: 4, maximum: 3)
            )
        }

        let emptyURL = directory.appendingPathComponent("empty.blob")
        XCTAssertTrue(FileManager.default.createFile(atPath: emptyURL.path, contents: nil))
        XCTAssertThrowsError(try EncryptedMediaUploadPolicy.validate(
            fileURL: emptyURL,
            declaredBlobSize: 0,
            maximumBytes: 4
        )) { error in
            XCTAssertEqual(error as? EncryptedMediaUploadPolicyError, .emptyFile)
        }
    }

    func testMultipartUploadBuilderStreamsExactBodyAcrossSmallChunks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KithraMultipartTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let blob = Data((0..<31).map(UInt8.init))
        let blobURL = directory.appendingPathComponent("ciphertext.blob")
        try blob.write(to: blobURL)
        let metadata = Data(#"{"message":"metadata"}"#.utf8)
        let boundary = "test-boundary"
        let multipart = try MultipartUploadFileBuilder.build(
            metadataData: metadata,
            encryptedBlobFileURL: blobURL,
            boundary: boundary,
            temporaryDirectory: directory,
            chunkSize: 7
        )

        let body = try Data(contentsOf: multipart.url)
        var expected = Data()
        expected.append(Data("--\(boundary)\r\n".utf8))
        expected.append(Data("Content-Disposition: form-data; name=\"metadata\"\r\n".utf8))
        expected.append(Data("Content-Type: application/json\r\n\r\n".utf8))
        expected.append(metadata)
        expected.append(Data("\r\n".utf8))
        expected.append(Data("--\(boundary)\r\n".utf8))
        expected.append(Data("Content-Disposition: form-data; name=\"blob\"; filename=\"encrypted-video.blob\"\r\n".utf8))
        expected.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        expected.append(blob)
        expected.append(Data("\r\n--\(boundary)--\r\n".utf8))

        XCTAssertEqual(body, expected)
        XCTAssertEqual(multipart.contentLength, Int64(expected.count))
    }

    func testRecordingBudgetCannotResetAcrossCameraSegments() {
        var budget = RecordingDurationBudget(maximumSeconds: 120)
        budget.includeSegment(durationSeconds: 70)
        XCTAssertEqual(budget.remainingSeconds, 50, accuracy: 0.001)
        budget.includeSegment(durationSeconds: 55)
        XCTAssertEqual(budget.recordedSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(budget.remainingSeconds, 0, accuracy: 0.001)
    }

    func testPlaybackStartNotificationFiresOnlyOnceWhenPlaybackActuallyStarts() {
        XCTAssertFalse(PlaybackStartNotification.shouldNotify(
            for: .paused,
            alreadyNotified: false
        ))
        XCTAssertFalse(PlaybackStartNotification.shouldNotify(
            for: .waitingToPlayAtSpecifiedRate,
            alreadyNotified: false
        ))
        XCTAssertTrue(PlaybackStartNotification.shouldNotify(
            for: .playing,
            alreadyNotified: false
        ))
        XCTAssertFalse(PlaybackStartNotification.shouldNotify(
            for: .playing,
            alreadyNotified: true
        ))
    }

    @MainActor
    func testMarkMessageWatchedPatchesReceivedMessageAndPreservesLocalMedia() async throws {
        let encoder = wireEncoder()
        var requestCount = 0
        let state = AppState(
            apiClient: makeAPIClient(token: "preview-token"),
            seedPreviewData: true
        )
        let contactID = try XCTUnwrap(state.contacts.first?.contactID)
        var received = try XCTUnwrap(
            state.messagesByContactID[contactID]?.first(where: {
                $0.recipientID == state.currentUser?.id && $0.status == .delivered
            })
        )
        let packageURL = URL(fileURLWithPath: "/tmp/watched-package-\(UUID().uuidString)")
        let thumbnailURL = URL(fileURLWithPath: "/tmp/watched-thumbnail-\(UUID().uuidString)")
        received.localEncryptedPackageURL = packageURL
        received.localThumbnailURL = thumbnailURL
        state.messagesByContactID[contactID] = state.messagesByContactID[contactID]?.map {
            $0.id == received.id ? received : $0
        }

        AuthenticationURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(
                request.url?.path,
                "/messages/\(received.id.uuidString)/status"
            )
            let body = try XCTUnwrap(request.bodyDataForTesting())
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(object["status"] as? String, MessageStatus.watched.rawValue)
            var response = received
            response.status = .watched
            response.localEncryptedPackageURL = nil
            response.localThumbnailURL = nil
            return (200, try encoder.encode(response))
        }

        await state.markMessageWatched(messageID: received.id)

        XCTAssertEqual(requestCount, 1)
        let updated = try XCTUnwrap(
            state.messagesByContactID[contactID]?.first(where: { $0.id == received.id })
        )
        XCTAssertEqual(updated.status, .watched)
        XCTAssertEqual(updated.localEncryptedPackageURL, packageURL)
        XCTAssertEqual(updated.localThumbnailURL, thumbnailURL)
    }

    @MainActor
    func testMarkMessageWatchedRetriesFailureAndRejectsStaleAccountResponse() async throws {
        let encoder = wireEncoder()
        var requestCount = 0
        let gate = RegistrationRequestGate()
        let state = AppState(
            apiClient: makeAPIClient(token: "preview-token"),
            seedPreviewData: true
        )
        let contactID = try XCTUnwrap(state.contacts.first?.contactID)
        let received = try XCTUnwrap(
            state.messagesByContactID[contactID]?.first(where: {
                $0.recipientID == state.currentUser?.id && $0.status == .delivered
            })
        )

        AuthenticationURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                return (500, Data("retry".utf8))
            }
            gate.recordRequestAndWait()
            var response = received
            response.status = .watched
            return (200, try encoder.encode(response))
        }

        await state.markMessageWatched(messageID: received.id)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            state.messagesByContactID[contactID]?.first(where: { $0.id == received.id })?.status,
            .delivered
        )

        let retry = Task { @MainActor in
            await state.markMessageWatched(messageID: received.id)
        }
        try await waitUntil { gate.requestCount == 1 }
        state.currentUser = nil
        gate.open()
        await retry.value

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(
            state.messagesByContactID[contactID]?.first(where: { $0.id == received.id })?.status,
            .delivered
        )
    }

    func testOnlyKnownLocalAndRelayRejectionsAreDefinitiveUploadFailures() {
        XCTAssertTrue(APIClientError.uploadNotAttempted("preflight").uploadWasDefinitelyNotAccepted)
        XCTAssertTrue(APIClientError.definitiveUploadRejection(413, Data()).uploadWasDefinitelyNotAccepted)
        XCTAssertTrue(APIClientError.definitiveUploadRejection(507, Data()).uploadWasDefinitelyNotAccepted)
        XCTAssertFalse(APIClientError.serverStatus(500, Data()).uploadWasDefinitelyNotAccepted)
    }

    func testChallengeAndLoginUseBoundChallengeIDContract() async throws {
        let challengeID = UUID()
        let deviceID = UUID()
        let challengeBytes = Data(repeating: 0x42, count: 32)
        let responseBytes = Data(repeating: 0x24, count: 64)
        let expectedSession = makeSession(deviceID: deviceID, token: "new-token")
        let encoder = wireEncoder()
        var observedPaths: [String] = []

        AuthenticationURLProtocol.handler = { request in
            observedPaths.append(request.url?.path ?? "")
            let body = try XCTUnwrap(request.bodyDataForTesting())
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            switch request.url?.path {
            case "/auth/challenge":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(object["username"] as? String, "alice")
                XCTAssertEqual(object["deviceID"] as? String, deviceID.uuidString)
                return (200, try encoder.encode(LoginChallenge(
                    challengeID: challengeID,
                    challenge: challengeBytes,
                    expiresAt: Date().addingTimeInterval(60)
                )))
            case "/auth/login":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(object["username"] as? String, "alice")
                XCTAssertEqual(object["deviceID"] as? String, deviceID.uuidString)
                XCTAssertEqual(object["challengeID"] as? String, challengeID.uuidString)
                XCTAssertEqual(object["challengeResponse"] as? String, responseBytes.base64EncodedString())
                return (200, try encoder.encode(expectedSession))
            default:
                return (404, Data())
            }
        }

        let client = makeAPIClient(token: nil)
        let challenge = try await client.requestLoginChallenge(username: "alice", deviceID: deviceID)
        XCTAssertEqual(challenge.challengeID, challengeID)
        XCTAssertEqual(challenge.challenge, challengeBytes)
        let session = try await client.login(
            username: "alice",
            deviceID: deviceID,
            challengeID: challenge.challengeID,
            challengeResponse: responseBytes
        )
        XCTAssertEqual(session, expectedSession)
        XCTAssertEqual(observedPaths, ["/auth/challenge", "/auth/login"])
    }

    func testUnauthorizedRequestRenewsAndRetriesExactlyOnce() async throws {
        var requestTokens: [String?] = []
        let recoveryCounter = AuthenticationRecoveryCounter()
        let renewedSession = makeSession(token: "renewed-token")
        AuthenticationURLProtocol.handler = { request in
            requestTokens.append(request.value(forHTTPHeaderField: "Authorization"))
            if requestTokens.count == 1 {
                return (401, Data("expired".utf8))
            }
            return (200, Data("[]".utf8))
        }

        let client = makeAPIClient(token: "old-token", expiresAt: Date().addingTimeInterval(600))
        await client.setAuthenticationRecoveryHandler {
            await recoveryCounter.increment()
            return renewedSession
        }

        let contacts = try await client.listContacts()
        XCTAssertEqual(contacts, [])
        let recoveryCount = await recoveryCounter.value
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(requestTokens, ["Bearer old-token", "Bearer renewed-token"])
    }

    func testUnauthorizedRetryStopsAfterSecond401() async throws {
        var requestCount = 0
        let recoveryCounter = AuthenticationRecoveryCounter()
        AuthenticationURLProtocol.handler = { _ in
            requestCount += 1
            return (401, Data("invalid".utf8))
        }

        let client = makeAPIClient(token: "old-token", expiresAt: Date().addingTimeInterval(600))
        let renewedSession = makeSession(token: "renewed-token")
        await client.setAuthenticationRecoveryHandler {
            await recoveryCounter.increment()
            return renewedSession
        }

        do {
            _ = try await client.listContacts()
            XCTFail("Expected the second 401 to be returned without another renewal loop")
        } catch APIClientError.serverStatus(let status, _) {
            XCTAssertEqual(status, 401)
        }
        XCTAssertEqual(requestCount, 2)
        let recoveryCount = await recoveryCounter.value
        XCTAssertEqual(recoveryCount, 1)
    }

    func testExpiredSessionRenewsBeforeSendingBearer() async throws {
        var requestTokens: [String?] = []
        let recoveryCounter = AuthenticationRecoveryCounter()
        AuthenticationURLProtocol.handler = { request in
            requestTokens.append(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data("[]".utf8))
        }

        let client = makeAPIClient(token: "expired-token", expiresAt: Date().addingTimeInterval(-1))
        let renewedSession = makeSession(token: "renewed-token")
        await client.setAuthenticationRecoveryHandler {
            await recoveryCounter.increment()
            return renewedSession
        }

        _ = try await client.listContacts()
        let recoveryCount = await recoveryCounter.value
        XCTAssertEqual(recoveryCount, 1)
        XCTAssertEqual(requestTokens, ["Bearer renewed-token"])
    }

    func testRenewalRejectsAnyIdentityReplacement() throws {
        let deviceID = UUID()
        let previous = makeSession(deviceID: deviceID, token: "old-token")
        var replacement = makeSession(deviceID: deviceID, token: "new-token")
        replacement.device.signingPublicKey = Data(repeating: 0x99, count: 32)
        let identity = DevicePublicIdentity(
            deviceID: deviceID,
            encryptionPublicKey: previous.device.encryptionPublicKey,
            signingPublicKey: previous.device.signingPublicKey,
            createdAt: previous.device.createdAt
        )

        XCTAssertThrowsError(try AuthSessionValidator.validateRenewal(
            replacement,
            replacing: previous,
            localIdentity: identity
        )) { error in
            XCTAssertEqual(error as? AuthSessionValidationError, .identityMismatch)
        }
    }

    func testExpiredChallengeAndExpiredSessionAreRejected() throws {
        XCTAssertThrowsError(try AuthSessionValidator.validateChallenge(LoginChallenge(
            challengeID: UUID(),
            challenge: Data(repeating: 1, count: 32),
            expiresAt: Date().addingTimeInterval(-1)
        )))

        let session = makeSession(token: "already-expired", expiresAt: Date().addingTimeInterval(-1))
        let identity = DevicePublicIdentity(
            deviceID: session.device.id,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        XCTAssertThrowsError(try AuthSessionValidator.validateRenewal(
            session,
            replacing: session,
            localIdentity: identity
        ))

        XCTAssertThrowsError(try AuthSessionValidator.validateChallenge(LoginChallenge(
            challengeID: UUID(),
            challenge: Data(repeating: 1, count: 31),
            expiresAt: Date().addingTimeInterval(60)
        )))
    }

    func testExpiredAndLegacySessionsAreAcceptedOnlyAsExactRecoveryClaims() throws {
        let deviceID = UUID()
        var expired = makeSession(
            deviceID: deviceID,
            token: "expired-token",
            expiresAt: Date().addingTimeInterval(-60)
        )
        let identity = DevicePublicIdentity(
            deviceID: deviceID,
            encryptionPublicKey: expired.device.encryptionPublicKey,
            signingPublicKey: expired.device.signingPublicKey,
            createdAt: expired.device.createdAt
        )

        XCTAssertNoThrow(try AuthSessionValidator.validateStoredRecoveryAuthority(
            expired,
            requestedUsername: "alice",
            localIdentity: identity
        ))
        expired.expiresAt = nil
        XCTAssertNoThrow(try AuthSessionValidator.validateStoredRecoveryAuthority(
            expired,
            requestedUsername: "alice",
            localIdentity: identity
        ))

        var wrongIdentity = identity
        wrongIdentity.signingPublicKey = Data(repeating: 0x99, count: 32)
        XCTAssertThrowsError(try AuthSessionValidator.validateStoredRecoveryAuthority(
            expired,
            requestedUsername: "alice",
            localIdentity: wrongIdentity
        )) { error in
            XCTAssertEqual(error as? AuthSessionValidationError, .identityMismatch)
        }
        XCTAssertThrowsError(try AuthSessionValidator.validateRegistration(
            expired,
            requestedUsername: "alice",
            localIdentity: identity
        )) { error in
            XCTAssertEqual(error as? AuthSessionValidationError, .missingOrExpiredSession)
        }
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for asynchronous authentication state")
        throw AuthenticationTestError.timeout
    }

    private func makeAPIClient(token: String?, expiresAt: Date? = nil) -> SpeakeasyAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationURLProtocol.self]
        return SpeakeasyAPIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://relay.example.test")!,
                bearerToken: token,
                sessionExpiresAt: expiresAt
            ),
            session: URLSession(configuration: configuration)
        )
    }

    private func makeSession(
        deviceID: UUID = UUID(),
        token: String,
        expiresAt: Date = Date(
            timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 3_600
        )
    ) -> AuthSession {
        let userID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        return AuthSession(
            user: SpeakeasyUser(id: userID, username: "alice", createdAt: now),
            device: SpeakeasyDevice(
                id: deviceID,
                userID: userID,
                name: "Kithra iOS",
                encryptionPublicKey: Data(repeating: 0x11, count: 32),
                signingPublicKey: Data(repeating: 0x22, count: 32),
                createdAt: now,
                lastSeenAt: now
            ),
            bearerToken: token,
            expiresAt: expiresAt
        )
    }

    private func wireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private final class AuthenticationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (status: Int, data: Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler,
                  let url = request.url else {
                throw APIClientError.invalidResponse
            }
            let result = try handler(request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: result.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw APIClientError.invalidResponse
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !result.data.isEmpty {
                client?.urlProtocol(self, didLoad: result.data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func bodyDataForTesting() -> Data? {
        if let httpBody {
            return httpBody
        }
        guard let httpBodyStream else {
            return nil
        }

        httpBodyStream.open()
        defer { httpBodyStream.close() }

        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var body = Data()
        while httpBodyStream.hasBytesAvailable {
            let count = httpBodyStream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                return nil
            }
            if count == 0 {
                break
            }
            body.append(buffer, count: count)
        }
        return body
    }
}

private actor AuthenticationRecoveryCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class RegistrationRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordRequestAndWait() {
        lock.lock()
        count += 1
        lock.unlock()
        semaphore.wait()
    }

    func open() {
        semaphore.signal()
    }
}

private enum AuthenticationTestError: Error {
    case saveFailed
    case bindFailed
    case timeout
    case unsupported
}

private final class InMemoryAuthSessionStore: AuthSessionStoring {
    private(set) var storedSession: StoredAuthSession?
    private(set) var didVerifySavedValue = false
    private(set) var loadCallCount = 0
    private(set) var removeCallCount = 0
    var loadError: Error?
    var saveError: Error?
    private let postSaveReadback: StoredAuthSession?
    private var hasSaved = false

    init(
        storedSession: StoredAuthSession? = nil,
        loadError: Error? = nil,
        saveError: Error? = nil,
        postSaveReadback: StoredAuthSession? = nil
    ) {
        self.storedSession = storedSession
        self.loadError = loadError
        self.saveError = saveError
        self.postSaveReadback = postSaveReadback
    }

    func load() throws -> StoredAuthSession? {
        loadCallCount += 1
        if let loadError {
            throw loadError
        }
        if hasSaved {
            let value = postSaveReadback ?? storedSession
            didVerifySavedValue = value == storedSession
            return value
        }
        return storedSession
    }

    func save(_ storedSession: StoredAuthSession) throws {
        if let saveError {
            throw saveError
        }
        self.storedSession = storedSession
        hasSaved = true
    }

    func remove() throws {
        removeCallCount += 1
        storedSession = nil
        hasSaved = false
    }
}

private final class InMemoryPendingRegistrationStore: PendingRegistrationStoring {
    private(set) var record: PendingRegistrationRecord?
    private(set) var loadCallCount = 0
    private(set) var removeCallCount = 0
    var loadError: Error?
    var saveError: Error?
    private let postSaveReadback: PendingRegistrationRecord?
    private var hasSaved = false

    init(
        record: PendingRegistrationRecord? = nil,
        loadError: Error? = nil,
        saveError: Error? = nil,
        postSaveReadback: PendingRegistrationRecord? = nil
    ) {
        self.record = record
        self.loadError = loadError
        self.saveError = saveError
        self.postSaveReadback = postSaveReadback
    }

    func load() throws -> PendingRegistrationRecord? {
        loadCallCount += 1
        if let loadError {
            throw loadError
        }
        return hasSaved ? (postSaveReadback ?? record) : record
    }

    func save(_ record: PendingRegistrationRecord) throws {
        if let saveError {
            throw saveError
        }
        self.record = record
        hasSaved = true
    }

    func remove() throws {
        removeCallCount += 1
        record = nil
        hasSaved = false
    }
}

private final class RegistrationRecoveryKeyManager: DeviceKeyManaging {
    private(set) var identity: DevicePublicIdentity?
    private(set) var bindCallCount = 0
    private(set) var loadOrCreateCallCount = 0
    private(set) var removeCallCount = 0
    private var bindFailuresRemaining: Int
    private let challengeResponse: Data

    init(
        identity: DevicePublicIdentity,
        bindFailuresRemaining: Int = 0,
        challengeResponse: Data = Data(repeating: 0x24, count: 64)
    ) {
        self.identity = identity
        self.bindFailuresRemaining = bindFailuresRemaining
        self.challengeResponse = challengeResponse
    }

    func currentIdentity() async throws -> DevicePublicIdentity? {
        identity
    }

    func loadOrCreateIdentity() async throws -> DevicePublicIdentity {
        loadOrCreateCallCount += 1
        guard let identity else {
            throw DeviceKeyManagerError.identityNotFound
        }
        return identity
    }

    func bindRegisteredDeviceID(_ deviceID: UUID) async throws -> DevicePublicIdentity {
        bindCallCount += 1
        if bindFailuresRemaining > 0 {
            bindFailuresRemaining -= 1
            throw AuthenticationTestError.bindFailed
        }
        guard var identity else {
            throw DeviceKeyManagerError.identityNotFound
        }
        identity.deviceID = deviceID
        self.identity = identity
        return identity
    }

    func storeGeneratedIdentity(
        deviceID: UUID?,
        encryptionPublicKey: Data,
        encryptionPrivateKey: Data,
        signingPublicKey: Data,
        signingPrivateKey: Data
    ) async throws -> DevicePublicIdentity {
        throw AuthenticationTestError.unsupported
    }

    func removeIdentity() async throws {
        removeCallCount += 1
        identity = nil
    }

    func makeLoginChallengeResponse(challenge: Data) async throws -> Data {
        challengeResponse
    }

    func signContactVerificationTranscript(_ transcript: Data) async throws -> Data {
        throw AuthenticationTestError.unsupported
    }

    func signMessageAuthenticationTranscript(_ transcript: Data) async throws -> Data {
        throw AuthenticationTestError.unsupported
    }

    func encryptContentKey(
        _ contentKey: Data,
        recipientPublicKey: Data
    ) async throws -> ContentKeyEnvelope {
        throw AuthenticationTestError.unsupported
    }

    func decryptContentKey(from envelope: ContentKeyEnvelope) async throws -> Data {
        throw AuthenticationTestError.unsupported
    }
}
