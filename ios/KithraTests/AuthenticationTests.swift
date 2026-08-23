import AVFoundation
import Foundation
import Security
import XCTest
@testable import Kithra

final class AuthenticationTests: XCTestCase {
    override func tearDown() {
        AuthenticationURLProtocol.handler = nil
        AuthenticationURLProtocol.responseHeaders = nil
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
            deviceID: session.device.id,
            deviceName: session.device.name,
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

    func testAccountDeletionIntentStoreRoundTripsWithThisDeviceOnlyAccessibility() throws {
        let service = "com.speakeasy.auth-session.tests.\(UUID().uuidString)"
        let account = "account-deletion-intent"
        let store = KeychainAccountDeletionIntentStore(
            service: service,
            account: account
        )
        defer { try? store.remove() }
        let session = makeSession(token: "deletion-intent-token")
        let record = PendingAccountDeletionRecord(
            protectedSession: StoredAuthSession(
                relayBaseURLString: "https://relay.example.test",
                session: session
            ),
            identity: boundIdentity(for: session)
        )

        try AccountDeletionIntentPersistence.saveAndVerify(record, in: store)
        XCTAssertEqual(try store.load(), record)

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

        try AccountDeletionIntentPersistence.removeAndVerify(from: store)
    }

    func testLegacyPendingRegistrationDecodesDeviceFieldsFromCompletedSession() throws {
        let session = makeSession(deviceID: UUID(), token: "legacy-pending-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let legacyRecord = LegacyPendingRegistrationRecord(
            relayBaseURLString: "https://relay.example.test",
            username: session.user.username,
            session: session,
            expectedIdentity: PendingRegistrationIdentity(identity)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let decoded = try decoder.decode(
            PendingRegistrationRecord.self,
            from: encoder.encode(legacyRecord)
        )

        XCTAssertEqual(decoded.deviceID, session.device.id)
        XCTAssertEqual(decoded.deviceName, session.device.name)
        XCTAssertEqual(decoded.session, session)
        XCTAssertEqual(
            decoded.storedSession,
            StoredAuthSession(
                relayBaseURLString: legacyRecord.relayBaseURLString,
                session: session
            )
        )
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
        let pendingStore = InMemoryPendingRegistrationStore()
        var registrationCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                registrationCount += 1
                let body = try XCTUnwrap(request.bodyDataForTesting())
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(object["deviceID"] as? String, deviceID.uuidString)
                XCTAssertEqual(pendingStore.record?.deviceID, deviceID)
                XCTAssertNil(
                    pendingStore.record?.session,
                    "The pre-request intent must be durable before the relay responds"
                )
                return (201, try encoder.encode(session))
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
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: { deviceID },
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: { session.device.id },
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
    func testPendingRegistrationPersistenceFailurePreventsRelayRequestUntilRetry() async throws {
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: { session.device.id },
            preferences: preferences,
            seedPreviewData: false
        )

        await state.register(username: "alice")
        XCTAssertNil(state.currentUser)
        XCTAssertEqual(registrationCount, 0, "No relay request may precede verified intent persistence")
        XCTAssertNil(deletionAuthorization)
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(pendingStore.record)

        pendingStore.saveError = nil
        await state.register(username: "alice")
        XCTAssertEqual(registrationCount, 1)
        XCTAssertEqual(state.currentUser, session.user)
    }

    @MainActor
    func testRegistrationRejectsRelayResponseForDifferentClientDeviceID() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let requestedDeviceID = UUID()
        let mismatchedSession = makeSession(
            deviceID: UUID(),
            token: "mismatched-device-token"
        )
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: mismatchedSession.device.encryptionPublicKey,
            signingPublicKey: mismatchedSession.device.signingPublicKey,
            createdAt: mismatchedSession.device.createdAt
        )
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let pendingStore = InMemoryPendingRegistrationStore()
        let encoder = wireEncoder()
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                return (201, try encoder.encode(mismatchedSession))
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: { requestedDeviceID },
            preferences: preferences,
            seedPreviewData: false
        )

        await state.register(username: "alice")

        XCTAssertNil(state.currentUser)
        XCTAssertEqual(keyManager.bindCallCount, 0)
        XCTAssertEqual(pendingStore.record?.deviceID, requestedDeviceID)
        XCTAssertNil(pendingStore.record?.session)
        XCTAssertTrue(state.needsAuthenticationRecoveryRetry)
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            preferences: preferences,
            seedPreviewData: false
        )

        try await waitUntil {
            state.currentUser != nil && !state.isRestoringSession
        }
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            preferences: preferences,
            seedPreviewData: false
        )

        try await waitUntil {
            state.currentUser != nil && !state.isRestoringSession
        }
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            preferences: preferences,
            seedPreviewData: false
        )

        try await waitUntil {
            state.currentUser != nil && !state.isRestoringSession
        }
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: { session.device.id },
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: { session.device.id },
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
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
    func testLostRegistrationResponseRetriesSameDurableDeviceIDAcrossRelaunch() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let deviceID = UUID()
        let recoveredSession = makeSession(deviceID: deviceID, token: "recovered-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: recoveredSession.device.encryptionPublicKey,
            signingPublicKey: recoveredSession.device.signingPublicKey,
            createdAt: recoveredSession.device.createdAt
        )
        let sessionStore = InMemoryAuthSessionStore()
        let pendingStore = InMemoryPendingRegistrationStore()
        let encoder = wireEncoder()
        var observedDeviceIDs: [UUID] = []
        var generatedDeviceIDCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                let body = try XCTUnwrap(request.bodyDataForTesting())
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                observedDeviceIDs.append(try XCTUnwrap(
                    (object["deviceID"] as? String).flatMap(UUID.init(uuidString:))
                ))
                XCTAssertEqual(pendingStore.record?.deviceID, deviceID)
                XCTAssertNil(pendingStore.record?.session)
                // Model a relay commit whose response never reached the app.
                throw URLError(.networkConnectionLost)
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: {
                generatedDeviceIDCount += 1
                return deviceID
            },
            preferences: preferences,
            seedPreviewData: false
        )

        await firstLaunch.register(username: "alice")
        let markers = LocalAccountBootstrapMarkers(preferences: preferences)
        XCTAssertTrue(markers.hasRegistrationUncertainty)
        XCTAssertTrue(firstLaunch.needsAuthenticationRecoveryRetry)
        XCTAssertTrue(firstLaunch.isPendingRegistrationResetBlocked)
        XCTAssertEqual(generatedDeviceIDCount, 1)
        XCTAssertEqual(pendingStore.record?.deviceID, deviceID)
        XCTAssertNil(pendingStore.record?.session)

        await firstLaunch.resetLocalRegistration(
            confirmation: .eraseProtectedLocalAccount
        )
        XCTAssertEqual(pendingStore.record?.deviceID, deviceID)
        XCTAssertEqual(keyManager.removeCallCount, 0)
        XCTAssertTrue(markers.hasRegistrationUncertainty)

        let challengeID = UUID()
        let challengeBytes = Data(repeating: 0x42, count: 32)
        var recoveryPaths: [String] = []
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/register":
                recoveryPaths.append("/auth/register")
                let body = try XCTUnwrap(request.bodyDataForTesting())
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                observedDeviceIDs.append(try XCTUnwrap(
                    (object["deviceID"] as? String).flatMap(UUID.init(uuidString:))
                ))
                return (409, Data("registration conflict".utf8))
            case "/auth/challenge":
                recoveryPaths.append("/auth/challenge")
                let body = try XCTUnwrap(request.bodyDataForTesting())
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(object["username"] as? String, "alice")
                XCTAssertEqual(object["deviceID"] as? String, deviceID.uuidString)
                return (201, try encoder.encode(LoginChallenge(
                    challengeID: challengeID,
                    challenge: challengeBytes,
                    expiresAt: Date().addingTimeInterval(60)
                )))
            case "/auth/login":
                recoveryPaths.append("/auth/login")
                let body = try XCTUnwrap(request.bodyDataForTesting())
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(object["username"] as? String, "alice")
                XCTAssertEqual(object["deviceID"] as? String, deviceID.uuidString)
                XCTAssertEqual(object["challengeID"] as? String, challengeID.uuidString)
                XCTAssertEqual(
                    object["challengeResponse"] as? String,
                    Data(repeating: 0x24, count: 64).base64EncodedString()
                )
                return (200, try encoder.encode(recoveredSession))
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }

        let relaunched = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: {
                generatedDeviceIDCount += 1
                return UUID()
            },
            preferences: preferences,
            seedPreviewData: false
        )
        try await waitUntil {
            relaunched.currentUser != nil
                && pendingStore.record == nil
                && !markers.hasRegistrationUncertainty
        }
        XCTAssertEqual(observedDeviceIDs, [deviceID, deviceID])
        XCTAssertEqual(Set(observedDeviceIDs).count, 1, "A retry must not identify a second relay account")
        XCTAssertEqual(recoveryPaths, ["/auth/register", "/auth/challenge", "/auth/login"])
        XCTAssertEqual(generatedDeviceIDCount, 1, "Relaunch recovery must reuse the durable ID")
        XCTAssertEqual(relaunched.currentUser, recoveredSession.user)
        XCTAssertEqual(relaunched.deviceIdentity?.deviceID, deviceID)
        XCTAssertEqual(
            sessionStore.storedSession,
            StoredAuthSession(
                relayBaseURLString: "https://relay.example.test",
                session: recoveredSession
            )
        )
        XCTAssertNil(pendingStore.record)
        XCTAssertFalse(markers.hasRegistrationUncertainty)
    }

    @MainActor
    func testRegistrationConflictWithoutMatchingDeviceClearsUnusedIntent() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let deviceID = UUID()
        let session = makeSession(deviceID: deviceID, token: "unused-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let pendingStore = InMemoryPendingRegistrationStore()
        var observedPaths: [String] = []
        AuthenticationURLProtocol.handler = { request in
            observedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/auth/register":
                return (409, Data("username is already taken".utf8))
            case "/auth/challenge":
                return (401, Data("invalid login identity".utf8))
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: { deviceID },
            preferences: preferences,
            seedPreviewData: false
        )

        await state.register(username: "alice")

        XCTAssertEqual(observedPaths, ["/auth/register", "/auth/challenge"])
        XCTAssertNil(state.currentUser)
        XCTAssertNil(pendingStore.record)
        XCTAssertFalse(state.needsAuthenticationRecoveryRetry)
        XCTAssertFalse(LocalAccountBootstrapMarkers(preferences: preferences).hasRegistrationUncertainty)
        XCTAssertTrue(state.lastErrorMessage?.contains("HTTP 409") == true)
    }

    @MainActor
    func testRegistrationConflictRecoveryRetainsIntentForChallengeAndLoginFailures() async throws {
        let suiteName = "KithraRegistrationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let deviceID = UUID()
        let session = makeSession(deviceID: deviceID, token: "unused-token")
        let identity = DevicePublicIdentity(
            deviceID: nil,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
        let pendingStore = InMemoryPendingRegistrationStore()
        let challenge = LoginChallenge(
            challengeID: UUID(),
            challenge: Data(repeating: 0x42, count: 32),
            expiresAt: Date().addingTimeInterval(60)
        )
        let encoder = wireEncoder()
        var challengeServerFailure = true
        var observedPaths: [String] = []
        AuthenticationURLProtocol.handler = { request in
            observedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/auth/register":
                return (409, Data("registration conflict".utf8))
            case "/auth/challenge":
                if challengeServerFailure {
                    return (500, Data("temporary failure".utf8))
                }
                return (201, try encoder.encode(challenge))
            case "/auth/login":
                return (401, Data("invalid or expired login challenge".utf8))
            default:
                return (404, Data())
            }
        }
        var generatedDeviceIDCount = 0
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: "https://relay.example.test")),
            apiClient: makeAPIClient(token: nil),
            keyManager: RegistrationRecoveryKeyManager(identity: identity),
            sessionStore: InMemoryAuthSessionStore(),
            pendingRegistrationStore: pendingStore,
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
            registrationDeviceIDProvider: {
                generatedDeviceIDCount += 1
                return deviceID
            },
            preferences: preferences,
            seedPreviewData: false
        )

        await state.register(username: "alice")
        XCTAssertEqual(observedPaths, ["/auth/register", "/auth/challenge"])
        XCTAssertEqual(pendingStore.record?.deviceID, deviceID)
        XCTAssertNil(pendingStore.record?.session)
        XCTAssertTrue(state.needsAuthenticationRecoveryRetry)

        challengeServerFailure = false
        await state.register(username: "alice")
        XCTAssertEqual(
            observedPaths,
            ["/auth/register", "/auth/challenge", "/auth/register", "/auth/challenge", "/auth/login"]
        )
        XCTAssertEqual(generatedDeviceIDCount, 1)
        XCTAssertEqual(pendingStore.record?.deviceID, deviceID)
        XCTAssertNil(pendingStore.record?.session)
        XCTAssertTrue(state.needsAuthenticationRecoveryRetry)
        XCTAssertTrue(LocalAccountBootstrapMarkers(preferences: preferences).hasRegistrationUncertainty)
        XCTAssertTrue(state.lastErrorMessage?.contains("HTTP 401") == true)
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
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
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
            contactTrustStore: EmptyContactTrustStore(),
            messageReplayStore: EmptyMessageReplayStore(),
            sessionStore: sessionStore,
            pendingRegistrationStore: pendingStore,
            accountDeletionIntentStore: InMemoryAccountDeletionIntentStore(),
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

    @MainActor
    func testAccountDeletionVerifiesProtectedIntentBeforeExact204AndCleansLocally() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(token: "delete-token")
        let identity = boundIdentity(for: session)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        ))
        let deletionStore = InMemoryAccountDeletionIntentStore()
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        var deleteCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            case "/account":
                deleteCount += 1
                XCTAssertTrue(deletionStore.didVerifySavedValue)
                XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer delete-token"
                )
                return (204, Data())
            default:
                return (404, Data())
            }
        }

        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { state.currentUser == session.user }
        let relayURL = state.relayBaseURLString

        await state.deleteAccount()

        XCTAssertEqual(deleteCount, 1)
        XCTAssertNil(deletionStore.record)
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(keyManager.identity)
        XCTAssertNil(state.currentUser)
        XCTAssertFalse(state.needsAccountDeletionRetry)
        XCTAssertFalse(state.needsLocalCleanupRetry)
        XCTAssertEqual(state.relayBaseURLString, relayURL)
        XCTAssertNil(LocalAccountBootstrapMarkers(preferences: preferences).cleanupStatus)
    }

    @MainActor
    func testPendingDeletionFencesDelayedOrdinary401RecoveryAndRetry() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(token: "ordinary-race-token")
        let identity = boundIdentity(for: session)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        ))
        let deletionStore = InMemoryAccountDeletionIntentStore()
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }

        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }
        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { state.currentUser == session.user && !state.isRestoringSession }

        let staleRequestGate = RegistrationRequestGate()
        defer { staleRequestGate.open() }
        var protectedRequestCount = 0
        var challengeCount = 0
        var loginCount = 0
        var deleteCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts":
                protectedRequestCount += 1
                staleRequestGate.recordRequestAndWait()
                return (401, Data("expired".utf8))
            case "/account":
                deleteCount += 1
                XCTAssertTrue(deletionStore.didVerifySavedValue)
                XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
                return (500, Data("retry deletion".utf8))
            case "/auth/challenge":
                challengeCount += 1
                return (500, Data())
            case "/auth/login":
                loginCount += 1
                return (500, Data())
            default:
                return (404, Data())
            }
        }

        let staleRefresh = Task { @MainActor in
            await state.refresh()
        }
        try await waitUntil { staleRequestGate.requestCount == 1 }
        let deletion = Task { @MainActor in
            await state.deleteAccount()
        }
        try await waitUntil {
            deletionStore.record?.phase == .awaitingRelayDeletion
                && state.currentUser == nil
        }
        // Release the stale 401 only after the deletion record is durable.
        // This avoids depending on URLSession running two protocol callbacks
        // concurrently while still exercising the post-intent recovery race.
        staleRequestGate.open()
        await staleRefresh.value
        await deletion.value

        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(protectedRequestCount, 1, "The stale protected request must not retry")
        XCTAssertEqual(challengeCount, 0, "Generic recovery is forbidden after deletion is durable")
        XCTAssertEqual(loginCount, 0)
        XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
        XCTAssertNil(state.currentUser)
        XCTAssertNotNil(sessionStore.storedSession)
        XCTAssertNotNil(keyManager.identity)
    }

    @MainActor
    func testConfirmedDeletionRetainsIntentWhenProtectedCleanupFailsThenRetriesLocally() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(token: "cleanup-retry-token")
        let identity = boundIdentity(for: session)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(
            storedSession: StoredAuthSession(
                relayBaseURLString: "https://relay.example.test",
                session: session
            ),
            removeError: AuthenticationTestError.saveFailed
        )
        let deletionStore = InMemoryAccountDeletionIntentStore()
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        var deleteCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            case "/account":
                deleteCount += 1
                return (204, Data())
            default:
                return (404, Data())
            }
        }
        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { state.currentUser == session.user && !state.isRestoringSession }

        await state.deleteAccount()

        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(deletionStore.record?.phase, .relayDeletionConfirmed)
        XCTAssertNotNil(sessionStore.storedSession)
        XCTAssertNil(state.currentUser)
        XCTAssertNil(state.deviceIdentity)
        XCTAssertTrue(state.needsLocalCleanupRetry)

        sessionStore.removeError = nil
        await state.retryPendingAccountDeletion()

        XCTAssertEqual(deleteCount, 1, "Confirmed cleanup retry must not contact the relay")
        XCTAssertNil(deletionStore.record)
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(keyManager.identity)
        XCTAssertFalse(state.needsAccountDeletionRetry)
        XCTAssertFalse(state.needsLocalCleanupRetry)
    }

    @MainActor
    func testPostClosePlaintextReservationIsRejectedBeforeFinalSweep() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(token: "late-plaintext-token")
        let identity = boundIdentity(for: session)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        ))
        let deletionStore = InMemoryAccountDeletionIntentStore()
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        let janitor = KithraPlaintextTempFileJanitor()
        let lateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kithra-inline-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        defer {
            janitor.release(lateURL)
            try? FileManager.default.removeItem(at: lateURL)
        }
        var deleteCount = 0
        var reservationWasRejected = false
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            case "/account":
                deleteCount += 1
                do {
                    try janitor.preserveWhileInUse(lateURL)
                    try Data("late plaintext".utf8).write(to: lateURL)
                    XCTFail("The closed deletion gate must reject a late producer")
                } catch MediaPipelineError.plaintextProductionInvalidated {
                    reservationWasRejected = true
                }
                return (204, Data())
            default:
                return (404, Data())
            }
        }
        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            plaintextTempJanitor: janitor,
            preferences: preferences
        )
        try await waitUntil { state.currentUser == session.user && !state.isRestoringSession }

        await state.deleteAccount()

        XCTAssertEqual(deleteCount, 1)
        XCTAssertTrue(reservationWasRejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateURL.path))
        XCTAssertNil(deletionStore.record)
        XCTAssertFalse(state.needsLocalCleanupRetry)
    }

    @MainActor
    func testAccountDeletionReadbackMismatchPreventsHTTPAndKeepsActiveAuthority() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)

        let session = makeSession(token: "readback-token")
        let stored = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        )
        let identity = boundIdentity(for: session)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(storedSession: stored)
        let mismatchedReadback = PendingAccountDeletionRecord(
            protectedSession: stored,
            identity: identity,
            phase: .relayDeletionConfirmed
        )
        let deletionStore = InMemoryAccountDeletionIntentStore(
            postSaveReadback: mismatchedReadback
        )
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        var deleteCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            case "/account":
                deleteCount += 1
                return (204, Data())
            default:
                return (404, Data())
            }
        }
        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { state.currentUser == session.user }

        await state.deleteAccount()

        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
        XCTAssertFalse(deletionStore.didVerifySavedValue)
        XCTAssertNil(state.currentUser)
        XCTAssertTrue(state.isAccountDeletionIntentStorageUncertain)
        XCTAssertTrue(state.needsAuthenticationStorageReload)
        XCTAssertNotNil(sessionStore.storedSession)
        XCTAssertNotNil(keyManager.identity)
    }

    @MainActor
    func testDefinitiveIntentSaveFailureReloadsNormalSessionWithoutDeletionState() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let session = makeSession(token: "save-failure-token")
        let keyManager = RegistrationRecoveryKeyManager(identity: boundIdentity(for: session))
        let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        ))
        let deletionStore = InMemoryAccountDeletionIntentStore(
            saveError: AuthenticationTestError.saveFailed
        )
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        var deleteCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            case "/account":
                deleteCount += 1
                return (204, Data())
            default:
                return (404, Data())
            }
        }
        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { state.currentUser == session.user }

        await state.deleteAccount()
        XCTAssertEqual(deleteCount, 0)
        XCTAssertNil(deletionStore.record)
        XCTAssertNil(state.currentUser)
        XCTAssertTrue(state.isAccountDeletionIntentStorageUncertain)
        XCTAssertTrue(state.needsAccountDeletionRetry)
        XCTAssertNotNil(sessionStore.storedSession)
        XCTAssertNotNil(keyManager.identity)

        deletionStore.saveError = nil
        await state.retryAuthenticationStorageLoad()
        try await waitUntil { state.currentUser == session.user }
        XCTAssertFalse(state.isAccountDeletionIntentStorageUncertain)
        XCTAssertFalse(state.needsAccountDeletionRetry)
        XCTAssertFalse(state.needsAuthenticationStorageReload)
        state.resumePlaintextProductionAfterBecomingActive()
        XCTAssertTrue(state.isPlaintextProductionEnabledForTesting)
    }

    @MainActor
    func testUnexpectedAccountDeletionSuccessResponsesRetainRetryAuthority() async throws {
        let responses: [(Int, Data)] = [
            (200, Data()),
            (202, Data()),
            (204, Data("unexpected".utf8))
        ]
        for (status, body) in responses {
            let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
            let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { preferences.removePersistentDomain(forName: suiteName) }
            preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
            let session = makeSession(token: "unexpected-\(status)")
            let keyManager = RegistrationRecoveryKeyManager(identity: boundIdentity(for: session))
            let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
                relayBaseURLString: "https://relay.example.test",
                session: session
            ))
            let deletionStore = InMemoryAccountDeletionIntentStore()
            let mediaRoot = deletionMediaRoot()
            defer { try? FileManager.default.removeItem(at: mediaRoot) }
            AuthenticationURLProtocol.handler = { request in
                switch request.url?.path {
                case "/contacts", "/messages":
                    return (200, Data("[]".utf8))
                case "/account":
                    return (status, body)
                default:
                    return (404, Data())
                }
            }
            let state = makeDeletionState(
                sessionStore: sessionStore,
                deletionStore: deletionStore,
                keyManager: keyManager,
                mediaRoot: mediaRoot,
                preferences: preferences
            )
            try await waitUntil { state.currentUser == session.user }

            await state.deleteAccount()

            XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
            XCTAssertTrue(state.needsAccountDeletionRetry)
            XCTAssertNotNil(sessionStore.storedSession)
            XCTAssertNotNil(keyManager.identity)
            XCTAssertNil(state.currentUser)
        }
    }

    @MainActor
    func testOrdinaryAccountDeletionFailureRetainsAuthorityAndExplicitRetryCleans() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let session = makeSession(token: "retry-token")
        let keyManager = RegistrationRecoveryKeyManager(identity: boundIdentity(for: session))
        let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        ))
        let deletionStore = InMemoryAccountDeletionIntentStore()
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        var shouldFail = true
        var deleteCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            case "/account":
                deleteCount += 1
                return shouldFail ? (500, Data("retry".utf8)) : (204, Data())
            default:
                return (404, Data())
            }
        }
        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { state.currentUser == session.user }

        await state.deleteAccount()
        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
        XCTAssertNotNil(keyManager.identity)

        shouldFail = false
        await state.retryPendingAccountDeletion()
        XCTAssertEqual(deleteCount, 2)
        XCTAssertNil(deletionStore.record)
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(keyManager.identity)
    }

    @MainActor
    func testLostDeleteResponseRelaunchUsesIdentityAbsence401ThenCleans() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let session = makeSession(token: "lost-response-token")
        let keyManager = RegistrationRecoveryKeyManager(identity: boundIdentity(for: session))
        let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        ))
        let deletionStore = InMemoryAccountDeletionIntentStore()
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            case "/account":
                throw URLError(.networkConnectionLost)
            default:
                return (404, Data())
            }
        }
        var firstLaunch: AppState? = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { firstLaunch?.currentUser == session.user }
        await firstLaunch?.deleteAccount()
        XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
        XCTAssertNotNil(sessionStore.storedSession)
        XCTAssertNotNil(keyManager.identity)
        firstLaunch = nil

        var replayPaths: [String] = []
        AuthenticationURLProtocol.responseHeaders = { request, _, _ in
            if request.url?.path == "/auth/challenge" {
                return ["Content-Type": "text/plain; charset=utf-8"]
            }
            return ["Content-Type": "application/json"]
        }
        AuthenticationURLProtocol.handler = { request in
            replayPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/account":
                return (401, Data("gone".utf8))
            case "/auth/challenge":
                return (401, Data("invalid login identity\n".utf8))
            default:
                return (404, Data())
            }
        }
        let relaunched = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil {
            deletionStore.record == nil && !relaunched.isRestoringSession
        }

        XCTAssertEqual(replayPaths, ["/account", "/auth/challenge"])
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(keyManager.identity)
        XCTAssertFalse(relaunched.needsAccountDeletionRetry)
    }

    @MainActor
    func testUnrelatedChallenge401NeverConfirmsAccountDeletion() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let session = makeSession(token: "proxy-401-token")
        let stored = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        )
        let identity = boundIdentity(for: session)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(storedSession: stored)
        let deletionStore = InMemoryAccountDeletionIntentStore(record:
            PendingAccountDeletionRecord(protectedSession: stored, identity: identity)
        )
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        AuthenticationURLProtocol.responseHeaders = { request, _, _ in
            if request.url?.path == "/auth/challenge" {
                return ["Content-Type": "text/plain; charset=utf-8"]
            }
            return ["Content-Type": "application/json"]
        }
        var paths: [String] = []
        AuthenticationURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/account":
                return (401, Data("invalid bearer token\n".utf8))
            case "/auth/challenge":
                return (401, Data("upstream access denied\n".utf8))
            default:
                return (404, Data())
            }
        }

        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { state.needsAccountDeletionRetry && !state.isRestoringSession }

        XCTAssertEqual(paths, ["/account", "/auth/challenge"])
        XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
        XCTAssertNotNil(sessionStore.storedSession)
        XCTAssertNotNil(keyManager.identity)
        XCTAssertFalse(state.needsLocalCleanupRetry)
    }

    @MainActor
    func testExactAbsenceBodyWithWrongContentTypeNeverConfirmsAccountDeletion() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let session = makeSession(token: "wrong-content-type-token")
        let stored = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        )
        let identity = boundIdentity(for: session)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(storedSession: stored)
        let deletionStore = InMemoryAccountDeletionIntentStore(record:
            PendingAccountDeletionRecord(protectedSession: stored, identity: identity)
        )
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        AuthenticationURLProtocol.responseHeaders = { request, _, _ in
            if request.url?.path == "/auth/challenge" {
                return ["Content-Type": "application/json"]
            }
            return ["Content-Type": "text/plain; charset=utf-8"]
        }
        var paths: [String] = []
        AuthenticationURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/account":
                return (401, Data("invalid bearer token\n".utf8))
            case "/auth/challenge":
                return (401, Data("invalid login identity\n".utf8))
            default:
                return (404, Data())
            }
        }

        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { state.needsAccountDeletionRetry && !state.isRestoringSession }

        XCTAssertEqual(paths, ["/account", "/auth/challenge"])
        XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
        XCTAssertNotNil(sessionStore.storedSession)
        XCTAssertNotNil(keyManager.identity)
        XCTAssertFalse(state.needsLocalCleanupRetry)
    }

    @MainActor
    func testPendingDeletionWithExpiredBearerRenewsThenRetriesExactDelete() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let deviceID = UUID()
        let expired = makeSession(
            deviceID: deviceID,
            token: "expired-delete-token",
            expiresAt: Date().addingTimeInterval(-60)
        )
        let renewed = makeSession(deviceID: deviceID, token: "renewed-delete-token")
        let stored = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: expired
        )
        let identity = boundIdentity(for: expired)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(storedSession: stored)
        let deletionStore = InMemoryAccountDeletionIntentStore(record:
            PendingAccountDeletionRecord(protectedSession: stored, identity: identity)
        )
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        let encoder = wireEncoder()
        let challenge = LoginChallenge(
            challengeID: UUID(),
            challenge: Data(repeating: 0x51, count: 32),
            expiresAt: Date().addingTimeInterval(60)
        )
        var paths: [String] = []
        AuthenticationURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/account":
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-delete-token" {
                    return (204, Data())
                }
                return (401, Data("expired".utf8))
            case "/auth/challenge":
                return (201, try encoder.encode(challenge))
            case "/auth/login":
                return (200, try encoder.encode(renewed))
            default:
                return (404, Data())
            }
        }

        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { deletionStore.record == nil && !state.isRestoringSession }

        XCTAssertEqual(paths, ["/account", "/auth/challenge", "/auth/login", "/account"])
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(keyManager.identity)
    }

    @MainActor
    func testConfirmedDeletionAndCleanupMarkerResumeLocallyWithoutHTTP() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.cleanupInProgressKey)
        let session = makeSession(token: "confirmed-token")
        let stored = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        )
        let identity = boundIdentity(for: session)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(storedSession: stored)
        let deletionStore = InMemoryAccountDeletionIntentStore(record:
            PendingAccountDeletionRecord(
                protectedSession: stored,
                identity: identity,
                phase: .relayDeletionConfirmed
            )
        )
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        var requestCount = 0
        AuthenticationURLProtocol.handler = { _ in
            requestCount += 1
            return (500, Data())
        }

        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { deletionStore.record == nil && !state.isRestoringSession }

        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(keyManager.identity)
        XCTAssertNil(LocalAccountBootstrapMarkers(preferences: preferences).cleanupStatus)
    }

    @MainActor
    func testUnreadableDeletionIntentBlocksResetThenUnlockReloadResumesCleanup() async throws {
        for loadError in [
            AuthSessionStoreError.keychain(errSecInteractionNotAllowed),
            AuthSessionStoreError.corruptAccountDeletionIntent
        ] {
            let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
            let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { preferences.removePersistentDomain(forName: suiteName) }
            preferences.set(true, forKey: LocalAccountBootstrapMarkers.cleanupInProgressKey)
            let session = makeSession(token: "locked-token")
            let stored = StoredAuthSession(
                relayBaseURLString: "https://relay.example.test",
                session: session
            )
            let identity = boundIdentity(for: session)
            let keyManager = RegistrationRecoveryKeyManager(identity: identity)
            let sessionStore = InMemoryAuthSessionStore(storedSession: stored)
            let deletionStore = InMemoryAccountDeletionIntentStore(
                record: PendingAccountDeletionRecord(
                    protectedSession: stored,
                    identity: identity,
                    phase: .relayDeletionConfirmed
                ),
                loadError: loadError
            )
            let mediaRoot = deletionMediaRoot()
            defer { try? FileManager.default.removeItem(at: mediaRoot) }
            AuthenticationURLProtocol.handler = { _ in
                XCTFail("Confirmed local cleanup must not contact the relay")
                return (500, Data())
            }
            let state = makeDeletionState(
                sessionStore: sessionStore,
                deletionStore: deletionStore,
                keyManager: keyManager,
                mediaRoot: mediaRoot,
                preferences: preferences
            )

            XCTAssertTrue(state.isAccountDeletionIntentStorageUncertain)
            XCTAssertTrue(state.needsLocalCleanupRetry)
            await state.resetLocalRegistration(confirmation: .eraseProtectedLocalAccount)
            XCTAssertNotNil(sessionStore.storedSession)
            XCTAssertNotNil(keyManager.identity)
            XCTAssertEqual(sessionStore.removeCallCount, 0)
            XCTAssertEqual(keyManager.removeCallCount, 0)

            deletionStore.loadError = nil
            await state.retryAccountDeletionIntentStorageLoad()
            try await waitUntil { deletionStore.record == nil && !state.isRestoringSession }
            XCTAssertNil(sessionStore.storedSession)
            XCTAssertNil(keyManager.identity)
            XCTAssertFalse(state.isAccountDeletionIntentStorageUncertain)
        }
    }

    @MainActor
    func testReadableDeletionIntentSurvivesSessionLoadFailureAndRetryReloadsBeforeDelete() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let session = makeSession(token: "session-locked-token")
        let stored = StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        )
        let identity = boundIdentity(for: session)
        let keyManager = RegistrationRecoveryKeyManager(identity: identity)
        let sessionStore = InMemoryAuthSessionStore(
            storedSession: stored,
            loadError: AuthSessionStoreError.keychain(errSecInteractionNotAllowed)
        )
        let deletionStore = InMemoryAccountDeletionIntentStore(record:
            PendingAccountDeletionRecord(protectedSession: stored, identity: identity)
        )
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        var deleteCount = 0
        AuthenticationURLProtocol.handler = { request in
            if request.url?.path == "/account" {
                deleteCount += 1
                return (204, Data())
            }
            return (404, Data())
        }
        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )

        XCTAssertTrue(state.needsAccountDeletionRetry)
        XCTAssertTrue(state.needsAuthenticationStorageReload)
        XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
        await state.resetLocalRegistration(confirmation: .eraseProtectedLocalAccount)
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(sessionStore.removeCallCount, 0)
        XCTAssertEqual(keyManager.removeCallCount, 0)

        sessionStore.loadError = nil
        await state.retryPendingAccountDeletion()
        try await waitUntil { deletionStore.record == nil && !state.isRestoringSession }
        XCTAssertEqual(deleteCount, 1)
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(keyManager.identity)
    }

    @MainActor
    func testDeletionSuspendsInFlightPlaintextAndCleansExactFilesBeforeHTTP() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let session = makeSession(token: "plaintext-token")
        let keyManager = RegistrationRecoveryKeyManager(identity: boundIdentity(for: session))
        let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        ))
        let deletionStore = InMemoryAccountDeletionIntentStore()
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        let tempRoot = mediaRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let activeURL = tempRoot
            .appendingPathComponent("playback-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        let inFlightURL = tempRoot
            .appendingPathComponent("playback-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try Data("plaintext".utf8).write(to: activeURL)
        try Data("plaintext".utf8).write(to: inFlightURL)
        let cancellation = DeletionCancellationBox()

        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            case "/account":
                XCTAssertFalse(FileManager.default.fileExists(atPath: activeURL.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: inFlightURL.path))
                return (500, Data("retry".utf8))
            default:
                return (404, Data())
            }
        }
        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            preferences: preferences
        )
        try await waitUntil { state.currentUser == session.user }
        state.activePlaybackFile = PlaybackTempFile(
            id: UUID(),
            url: activeURL,
            createdAt: Date(),
            cleanupDeadline: Date().addingTimeInterval(60)
        )
        let permit = PlaybackPreparationPermit()
        let operationID = try permit.beginOperation(outputURLs: [inFlightURL]) {
            cancellation.cancel()
        }
        XCTAssertTrue(permit.startOperation(operationID) {})
        state.installPlaybackPreparationPermitForTesting(permit)
        state.resumePlaintextProductionAfterBecomingActive()

        await state.deleteAccount()

        XCTAssertTrue(cancellation.wasCancelled)
        XCTAssertFalse(permit.isValid)
        XCTAssertNil(state.activePlaybackFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inFlightURL.path))
        state.resumePlaintextProductionAfterBecomingActive()
        XCTAssertFalse(state.isPlaintextProductionEnabledForTesting)
        XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
        XCTAssertNotNil(keyManager.identity)
    }

    @MainActor
    func testActiveRecognizedPlaintextBlocksDeleteUntilReleasedAndCleaned() async throws {
        let suiteName = "KithraAccountDeletionTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: LocalAccountBootstrapMarkers.installMarkerKey)
        let session = makeSession(token: "active-janitor-token")
        let keyManager = RegistrationRecoveryKeyManager(identity: boundIdentity(for: session))
        let sessionStore = InMemoryAuthSessionStore(storedSession: StoredAuthSession(
            relayBaseURLString: "https://relay.example.test",
            session: session
        ))
        let deletionStore = InMemoryAccountDeletionIntentStore()
        let mediaRoot = deletionMediaRoot()
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        let tempRoot = mediaRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let activeURL = tempRoot
            .appendingPathComponent("delivery-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        let janitor = KithraPlaintextTempFileJanitor()
        try janitor.beginProducing([activeURL])
        // Account-deletion's early unlink may release retained ownership, but
        // it must not erase the in-flight producer reservation.
        janitor.release(activeURL)
        defer {
            janitor.release(activeURL)
            try? FileManager.default.removeItem(at: activeURL)
        }
        var deleteCount = 0
        AuthenticationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/contacts", "/messages":
                return (200, Data("[]".utf8))
            case "/account":
                deleteCount += 1
                return (204, Data())
            default:
                return (404, Data())
            }
        }
        let state = makeDeletionState(
            sessionStore: sessionStore,
            deletionStore: deletionStore,
            keyManager: keyManager,
            mediaRoot: mediaRoot,
            plaintextTempJanitor: janitor,
            preferences: preferences
        )
        try await waitUntil { state.currentUser == session.user && !state.isRestoringSession }

        await state.deleteAccount()

        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(deletionStore.record?.phase, .awaitingRelayDeletion)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: activeURL.path),
            "An AV destination reservation must block deletion before the file exists"
        )
        XCTAssertNotNil(sessionStore.storedSession)
        XCTAssertNotNil(keyManager.identity)

        // Simulate AVFoundation recreating the destination after the early
        // unlink and first directory sweep, while its producer is still live.
        try Data("late active plaintext".utf8).write(to: activeURL)
        try FileManager.default.removeItem(at: activeURL)
        janitor.finishProducing([activeURL])
        await state.retryPendingAccountDeletion()

        XCTAssertEqual(deleteCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeURL.path))
        XCTAssertNil(deletionStore.record)
        XCTAssertNil(sessionStore.storedSession)
        XCTAssertNil(keyManager.identity)
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

        XCTAssertTrue(APIClientError.serverStatus(400, Data()).registrationWasDefinitelyNotAccepted)
        XCTAssertFalse(APIClientError.serverStatus(409, Data()).registrationWasDefinitelyNotAccepted)
        XCTAssertFalse(APIClientError.serverStatus(429, Data()).registrationWasDefinitelyNotAccepted)
        XCTAssertFalse(APIClientError.serverStatus(500, Data()).registrationWasDefinitelyNotAccepted)
        XCTAssertTrue(APIClientError.serverStatus(409, Data()).registrationRequiresSignedRecovery)
        XCTAssertFalse(APIClientError.serverStatus(400, Data()).registrationRequiresSignedRecovery)
        XCTAssertTrue(APIClientError.serverStatus(401, Data()).isUnauthorizedResponse)
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

    private func boundIdentity(for session: AuthSession) -> DevicePublicIdentity {
        DevicePublicIdentity(
            deviceID: session.device.id,
            encryptionPublicKey: session.device.encryptionPublicKey,
            signingPublicKey: session.device.signingPublicKey,
            createdAt: session.device.createdAt
        )
    }

    private func deletionMediaRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KithraAccountDeletionTests-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    @MainActor
    private func makeDeletionState(
        sessionStore: InMemoryAuthSessionStore,
        deletionStore: InMemoryAccountDeletionIntentStore,
        keyManager: RegistrationRecoveryKeyManager,
        mediaRoot: URL,
        plaintextTempJanitor: KithraPlaintextTempFileJanitor = KithraPlaintextTempFileJanitor(),
        preferences: UserDefaults
    ) -> AppState {
        AppState(
            relayBaseURL: URL(string: "https://relay.example.test")!,
            apiClient: makeAPIClient(token: nil),
            keyManager: keyManager,
            mediaPipeline: DefaultMediaPipeline(
                keyManager: keyManager,
                tempRoot: mediaRoot.appendingPathComponent("tmp", isDirectory: true),
                localMediaRoot: mediaRoot.appendingPathComponent("local", isDirectory: true),
                plaintextTempJanitor: plaintextTempJanitor
            ),
            contactTrustStore: EmptyContactTrustStore(),
            messageReplayStore: EmptyMessageReplayStore(),
            sessionStore: sessionStore,
            pendingRegistrationStore: InMemoryPendingRegistrationStore(),
            accountDeletionIntentStore: deletionStore,
            preferences: preferences,
            seedPreviewData: false
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

/// Exact JSON shape written by pre-C-REG builds: no durable top-level device
/// ID or device name, but a completed session from which both can be migrated.
private struct LegacyPendingRegistrationRecord: Encodable {
    var relayBaseURLString: String
    var username: String
    var session: AuthSession
    var expectedIdentity: PendingRegistrationIdentity
}

private final class AuthenticationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (status: Int, data: Data))?
    static var responseHeaders: ((URLRequest, Int, Data) -> [String: String])?

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
                headerFields: Self.responseHeaders?(
                    request,
                    result.status,
                    result.data
                ) ?? ["Content-Type": "application/json"]
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

private final class DeletionCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private enum AuthenticationTestError: Error {
    case saveFailed
    case bindFailed
    case timeout
    case unsupported
}

/// This recovery test is about choosing between the two authentication
/// namespaces. Keep unrelated trust and replay cleanup in memory so an
/// unsigned simulator build does not turn missing Keychain entitlements into
/// a false account-recovery failure.
private final class EmptyContactTrustStore: ContactTrustStoring {
    func observe(_ context: ContactVerificationContext) throws -> ContactTrustAssessment {
        ContactTrustAssessment(
            state: .unverified,
            candidateIdentity: context.remoteIdentity,
            trustedIdentity: nil,
            verificationMethod: nil,
            verifiedAt: nil
        )
    }

    func recordVerification(
        _ context: ContactVerificationContext,
        method: ContactVerificationMethod
    ) throws -> ContactTrustAssessment {
        ContactTrustAssessment(
            state: .verified,
            candidateIdentity: context.remoteIdentity,
            trustedIdentity: context.remoteIdentity,
            verificationMethod: method,
            verifiedAt: Date()
        )
    }

    func trustedIdentity(
        for context: ContactVerificationContext
    ) throws -> ContactVerificationIdentity? {
        nil
    }

    func status(for context: ContactVerificationContext) throws -> ContactTrustState {
        .unverified
    }

    func removeContact(_ scope: ContactTrustRemovalScope) throws {}
    func removeAll() throws {}
}

private actor EmptyMessageReplayStore: MessageReplayStoring {
    func reserveNetworkReceipt(
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) async throws -> MessageReplayReservation {
        .new
    }

    func markPendingReceiptCommitted(
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) async throws {}

    func validateLocalMessage(
        clientMessageID: UUID,
        serverMessageID: UUID,
        senderIdentityDigest: Data,
        relayScopeHash: Data,
        localDeviceID: UUID,
        authenticatedEnvelopeSignature: Data
    ) async throws {}

    func removeAll() async throws {}
}

private final class InMemoryAuthSessionStore: AuthSessionStoring {
    private(set) var storedSession: StoredAuthSession?
    private(set) var didVerifySavedValue = false
    private(set) var loadCallCount = 0
    private(set) var removeCallCount = 0
    var loadError: Error?
    var saveError: Error?
    var removeError: Error?
    private let postSaveReadback: StoredAuthSession?
    private var hasSaved = false

    init(
        storedSession: StoredAuthSession? = nil,
        loadError: Error? = nil,
        saveError: Error? = nil,
        removeError: Error? = nil,
        postSaveReadback: StoredAuthSession? = nil
    ) {
        self.storedSession = storedSession
        self.loadError = loadError
        self.saveError = saveError
        self.removeError = removeError
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
        if let removeError {
            throw removeError
        }
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

private final class InMemoryAccountDeletionIntentStore: AccountDeletionIntentStoring {
    private(set) var record: PendingAccountDeletionRecord?
    private(set) var loadCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var removeCallCount = 0
    private(set) var didVerifySavedValue = false
    var loadError: Error?
    var saveError: Error?
    var removeError: Error?
    var postSaveReadback: PendingAccountDeletionRecord?
    private var hasSaved = false

    init(
        record: PendingAccountDeletionRecord? = nil,
        loadError: Error? = nil,
        saveError: Error? = nil,
        removeError: Error? = nil,
        postSaveReadback: PendingAccountDeletionRecord? = nil
    ) {
        self.record = record
        self.loadError = loadError
        self.saveError = saveError
        self.removeError = removeError
        self.postSaveReadback = postSaveReadback
    }

    func load() throws -> PendingAccountDeletionRecord? {
        loadCallCount += 1
        if let loadError {
            throw loadError
        }
        let value = hasSaved ? (postSaveReadback ?? record) : record
        if hasSaved {
            didVerifySavedValue = value == record
        }
        return value
    }

    func save(_ record: PendingAccountDeletionRecord) throws {
        saveCallCount += 1
        if let saveError {
            throw saveError
        }
        self.record = record
        hasSaved = true
    }

    func remove() throws {
        removeCallCount += 1
        if let removeError {
            throw removeError
        }
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
