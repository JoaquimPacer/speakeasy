import Foundation
import XCTest
@testable import Kithra

final class TrustReplayStoreTests: XCTestCase {
    @MainActor
    func testManualSafetyConfirmationPinsOnlyTheExactCurrentDigest() async throws {
        let store = RecordingContactTrustStore()
        let state = AppState(contactTrustStore: store, seedPreviewData: true)
        let contact = try XCTUnwrap(state.contacts.first)
        let expectedDigest = try XCTUnwrap(state.safetyNumber(for: contact)).digest

        let confirmed = await state.confirmSafetyNumberComparison(
            for: contact,
            expectedSafetyDigest: expectedDigest
        )

        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.recordedContexts.count, 1)
        XCTAssertTrue(try XCTUnwrap(store.recordedContexts.first).remoteIdentity.constantTimeEquals(
            try ContactVerificationContext(
                relayURL: URL(string: state.relayBaseURLString)!,
                localUser: try XCTUnwrap(state.currentUser),
                localDeviceIdentity: try XCTUnwrap(state.deviceIdentity),
                contact: contact
            ).remoteIdentity
        ))
    }

    @MainActor
    func testManualSafetyConfirmationRejectsARefreshedIdentity() async throws {
        let store = RecordingContactTrustStore()
        let state = AppState(contactTrustStore: store, seedPreviewData: true)
        let displayedContact = try XCTUnwrap(state.contacts.first)
        let displayedDigest = try XCTUnwrap(state.safetyNumber(for: displayedContact)).digest
        state.contacts[0].encryptionPublicKey = Data(repeating: 0x55, count: 32)

        let confirmed = await state.confirmSafetyNumberComparison(
            for: displayedContact,
            expectedSafetyDigest: displayedDigest
        )

        XCTAssertFalse(confirmed)
        XCTAssertTrue(store.recordedContexts.isEmpty)
    }

    @MainActor
    func testVerificationRequiresTheContactToRemainPresent() async throws {
        let store = RecordingContactTrustStore()
        let state = AppState(contactTrustStore: store, seedPreviewData: true)
        let displayedContact = try XCTUnwrap(state.contacts.first)
        let displayedDigest = try XCTUnwrap(state.safetyNumber(for: displayedContact)).digest
        state.contacts = []

        XCTAssertNil(state.safetyNumber(for: displayedContact))
        let confirmed = await state.confirmSafetyNumberComparison(
            for: displayedContact,
            expectedSafetyDigest: displayedDigest
        )

        XCTAssertFalse(confirmed)
        XCTAssertTrue(store.recordedContexts.isEmpty)
    }

    @MainActor
    func testDeleteContactSweepsTheSameTrustScopeBeforeAndAfterTheRelayMutation() async throws {
        let (state, store) = try makeContactMutationState()
        let contact = try XCTUnwrap(state.contacts.first)

        await state.deleteContact(contact)

        XCTAssertNil(state.lastErrorMessage)
        XCTAssertFalse(state.contacts.contains { $0.contactID == contact.contactID })
        XCTAssertEqual(store.removedScopes.count, 2)
        XCTAssertEqual(store.removedScopes.first, store.removedScopes.last)
    }

    @MainActor
    func testBlockContactSweepsTheSameTrustScopeBeforeAndAfterTheRelayMutation() async throws {
        let (state, store) = try makeContactMutationState()
        let contact = try XCTUnwrap(state.contacts.first)

        await state.blockContact(contact)

        XCTAssertNil(state.lastErrorMessage)
        XCTAssertFalse(state.contacts.contains { $0.contactID == contact.contactID })
        XCTAssertEqual(store.removedScopes.count, 2)
        XCTAssertEqual(store.removedScopes.first, store.removedScopes.last)
    }

    func testTrustStoreFailsClosedAfterVerifiedContactKeyChanges() throws {
        let store = KeychainContactTrustStore(service: "com.kithra.tests.trust.\(UUID().uuidString)")
        try? store.removeAll()
        addTeardownBlock {
            try store.removeAll()
        }

        let original = try makeVerificationContext(remoteEncryptionByte: 0x31)
        XCTAssertEqual(try store.observe(original).state, .unverified)

        let verified = try store.recordVerification(original, method: .qrCode)
        XCTAssertEqual(verified.state, .verified)
        XCTAssertEqual(verified.verificationMethod, .qrCode)
        XCTAssertTrue(try XCTUnwrap(store.trustedIdentity(for: original)).constantTimeEquals(
            original.remoteIdentity
        ))

        let changed = try makeVerificationContext(remoteEncryptionByte: 0x32)
        let assessment = try store.observe(changed)
        XCTAssertEqual(assessment.state, .keyChanged)
        XCTAssertTrue(try XCTUnwrap(assessment.trustedIdentity).constantTimeEquals(
            original.remoteIdentity
        ))
        XCTAssertFalse(try XCTUnwrap(assessment.trustedIdentity).constantTimeEquals(
            changed.remoteIdentity
        ))
        XCTAssertEqual(try store.status(for: changed), .keyChanged)
    }

    func testTrustRemovalDoesNotRequireValidRemoteNameOrPublicKeys() throws {
        let store = KeychainContactTrustStore(service: "com.kithra.tests.trust.remove.\(UUID().uuidString)")
        try store.removeAll()
        addTeardownBlock {
            try store.removeAll()
        }

        let relayURL = try XCTUnwrap(URL(string: "https://relay.example.test"))
        let original = try makeVerificationContext(remoteEncryptionByte: 0x31)
        XCTAssertEqual(
            try store.recordVerification(original, method: .safetyNumberComparison).state,
            .verified
        )

        let now = Date(timeIntervalSince1970: 1_785_691_112)
        let localUser = SpeakeasyUser(
            id: original.localIdentity.userID,
            username: original.localIdentity.username,
            createdAt: now
        )
        let localDeviceIdentity = DevicePublicIdentity(
            deviceID: original.localIdentity.deviceID,
            encryptionPublicKey: original.localIdentity.encryptionPublicKey,
            signingPublicKey: original.localIdentity.signingPublicKey,
            createdAt: now
        )
        let malformedContact = Contact(
            userID: original.localIdentity.userID,
            contactID: original.remoteIdentity.userID,
            deviceID: original.remoteIdentity.deviceID,
            username: "",
            nickname: nil,
            encryptionPublicKey: Data([0x01]),
            signingPublicKey: Data(),
            createdAt: now
        )

        XCTAssertThrowsError(try ContactVerificationContext(
            relayURL: relayURL,
            localUser: localUser,
            localDeviceIdentity: localDeviceIdentity,
            contact: malformedContact
        ))

        // The same canonical relay origin, expressed with a default port and a
        // path, still targets the pin without reading the malformed candidates.
        try store.removeContact(
            malformedContact,
            localDeviceIdentity: localDeviceIdentity,
            localUser: localUser,
            relayURL: try XCTUnwrap(URL(string: "https://RELAY.example.test:443/ignored"))
        )

        XCTAssertNil(try store.trustedIdentity(for: original))
        XCTAssertEqual(try store.status(for: original), .unverified)
    }

    func testTrustRemovalClearsPriorDevicePinsOnlyWithinCanonicalRelayScope() throws {
        let store = KeychainContactTrustStore(service: "com.kithra.tests.trust.remove-history.\(UUID().uuidString)")
        try store.removeAll()
        addTeardownBlock {
            try store.removeAll()
        }

        let original = try makeVerificationContext(remoteEncryptionByte: 0x31)
        let replacementDeviceID = try XCTUnwrap(
            UUID(uuidString: "99999999-aaaa-4bbb-8ccc-dddddddddddd")
        )
        let replacement = try makeVerificationContext(
            remoteEncryptionByte: 0x32,
            remoteDeviceID: replacementDeviceID
        )
        XCTAssertEqual(try store.recordVerification(original, method: .qrCode).state, .verified)
        XCTAssertEqual(try store.observe(replacement).state, .keyChanged)

        let otherRelayScope = try ContactTrustRemovalScope(
            relayURL: try XCTUnwrap(URL(string: "https://other-relay.example.test")),
            localUserID: replacement.localIdentity.userID,
            localDeviceID: replacement.localIdentity.deviceID,
            remoteUserID: replacement.remoteIdentity.userID,
            remoteDeviceID: replacement.remoteIdentity.deviceID
        )
        try store.removeContact(otherRelayScope)
        XCTAssertEqual(try store.status(for: replacement), .keyChanged)

        let removalScope = try ContactTrustRemovalScope(
            relayURL: try XCTUnwrap(URL(string: "https://RELAY.example.test:443/some/path")),
            localUserID: replacement.localIdentity.userID,
            localDeviceID: replacement.localIdentity.deviceID,
            remoteUserID: replacement.remoteIdentity.userID,
            remoteDeviceID: replacement.remoteIdentity.deviceID
        )
        try store.removeContact(removalScope)

        XCTAssertNil(try store.trustedIdentity(for: replacement))
        XCTAssertNil(try store.trustedIdentity(for: original))
        XCTAssertEqual(try store.status(for: replacement), .unverified)
        XCTAssertEqual(try store.status(for: original), .unverified)
    }

    func testReplayReservationReturnsNewThenKeepsExactPendingReceiptRecoverable() async throws {
        let (store, fixture) = try await makeReplayStore()

        let firstReservation = try await reserve(store, fixture)
        XCTAssertEqual(firstReservation, .new)

        let recoveredReservation = try await reserve(store, fixture)
        XCTAssertEqual(recoveredReservation, .recoveringPending)
    }

    func testCommittedReceiptRejectsAnotherNetworkReservationButAllowsExactLocalValidation() async throws {
        let (store, fixture) = try await makeReplayStore()
        _ = try await reserve(store, fixture)

        try await commit(store, fixture)
        try await validate(store, fixture)

        // The exact commit transition is idempotent if SecItemUpdate completed
        // immediately before an interruption.
        try await commit(store, fixture)

        do {
            _ = try await reserve(store, fixture)
            XCTFail("Expected a committed network receipt to reject a duplicate reservation")
        } catch MessageReplayStoreError.replayDetected {
            // Expected.
        }

        try await validate(store, fixture)
    }

    func testMismatchedPendingReceiptIsReplayAndCannotBeCommitted() async throws {
        let (store, fixture) = try await makeReplayStore()
        _ = try await reserve(store, fixture)
        let changedServerID = UUID()
        let changedSignature = Data(repeating: 0x62, count: 64)

        do {
            _ = try await reserve(store, fixture, serverMessageID: changedServerID)
            XCTFail("Expected a changed server ID on the same pending tuple to be a replay")
        } catch MessageReplayStoreError.replayDetected {
            // Expected.
        }

        do {
            _ = try await reserve(store, fixture, signature: changedSignature)
            XCTFail("Expected a changed signature on the same pending tuple to be a replay")
        } catch MessageReplayStoreError.replayDetected {
            // Expected.
        }

        do {
            try await commit(store, fixture, signature: changedSignature)
            XCTFail("Expected a mismatched pending receipt not to be committed")
        } catch MessageReplayStoreError.replayDetected {
            // Expected.
        }

        // All mismatched operations left the exact pending reservation intact
        // for retry. There is deliberately no deletion-style cancellation API.
        let recoveredReservation = try await reserve(store, fixture)
        XCTAssertEqual(recoveredReservation, .recoveringPending)
        try await commit(store, fixture)
        try await validate(store, fixture)
    }

    func testExactLocalValidationPromotesPendingReceiptAfterFileCommitCrash() async throws {
        let (store, fixture) = try await makeReplayStore()
        _ = try await reserve(store, fixture)

        // Local validation is called only after the exact authenticated file is
        // present, so it completes the interrupted pending -> committed step.
        try await validate(store, fixture)
        try await validate(store, fixture)

        do {
            _ = try await reserve(store, fixture)
            XCTFail("Expected the promoted receipt to reject network replay")
        } catch MessageReplayStoreError.replayDetected {
            // Expected.
        }
    }

    func testLocalValidationFailsClosedForPendingAndCommittedMismatches() async throws {
        let (store, fixture) = try await makeReplayStore()
        _ = try await reserve(store, fixture)
        let changedSignature = Data(repeating: 0x63, count: 64)

        do {
            try await validate(store, fixture, signature: changedSignature)
            XCTFail("Expected a mismatched pending local receipt to be a replay")
        } catch MessageReplayStoreError.replayDetected {
            // Expected.
        }

        let stillPending = try await reserve(store, fixture)
        XCTAssertEqual(stillPending, .recoveringPending)
        try await commit(store, fixture)

        do {
            try await validate(store, fixture, serverMessageID: UUID())
            XCTFail("Expected a changed server ID to fail committed local validation")
        } catch MessageReplayStoreError.mismatchedLocalRecord {
            // Expected.
        }

        do {
            try await validate(store, fixture, signature: changedSignature)
            XCTFail("Expected a changed signature to fail committed local validation")
        } catch MessageReplayStoreError.mismatchedLocalRecord {
            // Expected.
        }

        var unknown = fixture
        unknown.clientMessageID = UUID()
        do {
            try await validate(store, unknown)
            XCTFail("Expected an unknown local tuple to be rejected")
        } catch MessageReplayStoreError.missingLocalRecord {
            // Expected.
        }
    }

    func testReplayTupleSeparatesSenderRelayDeviceAndClientMessage() async throws {
        let (store, fixture) = try await makeReplayStore()
        let first = try await reserve(store, fixture)
        XCTAssertEqual(first, .new)

        var differentSender = fixture
        differentSender.senderIdentityDigest = Data(repeating: 0x42, count: 32)
        let senderReservation = try await reserve(store, differentSender)
        XCTAssertEqual(senderReservation, .new)

        var differentRelay = fixture
        differentRelay.relayScopeHash = Data(repeating: 0x52, count: 32)
        let relayReservation = try await reserve(store, differentRelay)
        XCTAssertEqual(relayReservation, .new)

        var differentDevice = fixture
        differentDevice.localDeviceID = UUID()
        let deviceReservation = try await reserve(store, differentDevice)
        XCTAssertEqual(deviceReservation, .new)

        var differentClientMessage = fixture
        differentClientMessage.clientMessageID = UUID()
        let clientReservation = try await reserve(store, differentClientMessage)
        XCTAssertEqual(clientReservation, .new)
    }

    func testReplayTuplePersistsAsOneKeychainItemAcrossStoreInstances() async throws {
        let service = "com.kithra.tests.replay.shared.\(UUID().uuidString)"
        let firstStore = KeychainMessageReplayStore(service: service)
        let secondStore = KeychainMessageReplayStore(service: service)
        let fixture = try ReplayFixture()
        try await firstStore.removeAll()
        addTeardownBlock {
            try await firstStore.removeAll()
        }

        let initial = try await reserve(firstStore, fixture)
        XCTAssertEqual(initial, .new)

        let recovered = try await reserve(secondStore, fixture)
        XCTAssertEqual(recovered, .recoveringPending)

        do {
            _ = try await reserve(
                secondStore,
                fixture,
                signature: Data(repeating: 0x7f, count: 64)
            )
            XCTFail("Expected the persisted tuple not to accept a second receipt item")
        } catch MessageReplayStoreError.replayDetected {
            // Expected.
        }
    }

    func testMissingPendingTransitionsFailClosed() async throws {
        let (store, fixture) = try await makeReplayStore()

        do {
            try await commit(store, fixture)
            XCTFail("Expected a missing pending receipt not to be committed")
        } catch MessageReplayStoreError.missingLocalRecord {
            // Expected.
        }

        do {
            try await validate(store, fixture)
            XCTFail("Expected a missing local receipt not to validate")
        } catch MessageReplayStoreError.missingLocalRecord {
            // Expected.
        }
    }

    func testReplayStoreRejectsInvalidDigestSignatureAndIdentifierFields() async throws {
        let (store, fixture) = try await makeReplayStore()

        var invalidCases = [fixture]
        invalidCases[0].senderIdentityDigest = Data(repeating: 0, count: 31)

        var shortRelayDigest = fixture
        shortRelayDigest.relayScopeHash = Data(repeating: 0, count: 31)
        invalidCases.append(shortRelayDigest)

        var shortSignature = fixture
        shortSignature.signature = Data(repeating: 0, count: 63)
        invalidCases.append(shortSignature)

        var longSignature = fixture
        longSignature.signature = Data(repeating: 0, count: 65)
        invalidCases.append(longSignature)

        var zeroClientID = fixture
        zeroClientID.clientMessageID = Self.zeroUUID
        invalidCases.append(zeroClientID)

        var zeroServerID = fixture
        zeroServerID.serverMessageID = Self.zeroUUID
        invalidCases.append(zeroServerID)

        var zeroDeviceID = fixture
        zeroDeviceID.localDeviceID = Self.zeroUUID
        invalidCases.append(zeroDeviceID)

        for invalid in invalidCases {
            do {
                _ = try await reserve(store, invalid)
                XCTFail("Expected an invalid replay receipt field to be rejected")
            } catch MessageReplayStoreError.invalidField {
                // Expected.
            }
        }
    }

    private func makeReplayStore() async throws -> (KeychainMessageReplayStore, ReplayFixture) {
        let store = KeychainMessageReplayStore(
            service: "com.kithra.tests.replay.\(UUID().uuidString)"
        )
        try await store.removeAll()
        addTeardownBlock {
            try await store.removeAll()
        }
        return (store, try ReplayFixture())
    }

    private func reserve(
        _ store: KeychainMessageReplayStore,
        _ fixture: ReplayFixture,
        serverMessageID: UUID? = nil,
        signature: Data? = nil
    ) async throws -> MessageReplayReservation {
        try await store.reserveNetworkReceipt(
            clientMessageID: fixture.clientMessageID,
            serverMessageID: serverMessageID ?? fixture.serverMessageID,
            senderIdentityDigest: fixture.senderIdentityDigest,
            relayScopeHash: fixture.relayScopeHash,
            localDeviceID: fixture.localDeviceID,
            authenticatedEnvelopeSignature: signature ?? fixture.signature
        )
    }

    private func commit(
        _ store: KeychainMessageReplayStore,
        _ fixture: ReplayFixture,
        serverMessageID: UUID? = nil,
        signature: Data? = nil
    ) async throws {
        try await store.markPendingReceiptCommitted(
            clientMessageID: fixture.clientMessageID,
            serverMessageID: serverMessageID ?? fixture.serverMessageID,
            senderIdentityDigest: fixture.senderIdentityDigest,
            relayScopeHash: fixture.relayScopeHash,
            localDeviceID: fixture.localDeviceID,
            authenticatedEnvelopeSignature: signature ?? fixture.signature
        )
    }

    private func validate(
        _ store: KeychainMessageReplayStore,
        _ fixture: ReplayFixture,
        serverMessageID: UUID? = nil,
        signature: Data? = nil
    ) async throws {
        try await store.validateLocalMessage(
            clientMessageID: fixture.clientMessageID,
            serverMessageID: serverMessageID ?? fixture.serverMessageID,
            senderIdentityDigest: fixture.senderIdentityDigest,
            relayScopeHash: fixture.relayScopeHash,
            localDeviceID: fixture.localDeviceID,
            authenticatedEnvelopeSignature: signature ?? fixture.signature
        )
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private func makeVerificationContext(
        remoteEncryptionByte: UInt8,
        remoteDeviceID: UUID? = nil
    ) throws -> ContactVerificationContext {
        let relayURL = try XCTUnwrap(URL(string: "https://relay.example.test"))
        let localUserID = try XCTUnwrap(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        let localDeviceID = try XCTUnwrap(UUID(uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa"))
        let remoteUserID = try XCTUnwrap(UUID(uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"))
        let defaultRemoteDeviceID = try XCTUnwrap(
            UUID(uuidString: "01234567-89ab-4cde-8f01-23456789abcd")
        )
        let now = Date(timeIntervalSince1970: 1_785_691_112)

        return try ContactVerificationContext(
            relayURL: relayURL,
            localUser: SpeakeasyUser(id: localUserID, username: "Alice", createdAt: now),
            localDeviceIdentity: DevicePublicIdentity(
                deviceID: localDeviceID,
                encryptionPublicKey: Data(repeating: 0x11, count: 32),
                signingPublicKey: Data(repeating: 0x21, count: 32),
                createdAt: now
            ),
            contact: Contact(
                userID: localUserID,
                contactID: remoteUserID,
                deviceID: remoteDeviceID ?? defaultRemoteDeviceID,
                username: "Bob",
                nickname: nil,
                encryptionPublicKey: Data(repeating: remoteEncryptionByte, count: 32),
                signingPublicKey: Data(repeating: 0x41, count: 32),
                createdAt: now
            )
        )
    }

    @MainActor
    private func makeContactMutationState() throws -> (AppState, RecordingContactTrustStore) {
        let relayURL = try XCTUnwrap(URL(string: "https://relay.example.test"))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SuccessfulContactMutationURLProtocol.self]
        let apiClient = SpeakeasyAPIClient(
            configuration: APIConfiguration(baseURL: relayURL, bearerToken: "test-token"),
            session: URLSession(configuration: sessionConfiguration)
        )
        let store = RecordingContactTrustStore()
        return (
            AppState(
                relayBaseURL: relayURL,
                apiClient: apiClient,
                contactTrustStore: store,
                seedPreviewData: true
            ),
            store
        )
    }
}

private final class RecordingContactTrustStore: ContactTrustStoring {
    private(set) var recordedContexts: [ContactVerificationContext] = []
    private(set) var removedScopes: [ContactTrustRemovalScope] = []

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
        recordedContexts.append(context)
        return ContactTrustAssessment(
            state: .verified,
            candidateIdentity: context.remoteIdentity,
            trustedIdentity: context.remoteIdentity,
            verificationMethod: method,
            verifiedAt: Date()
        )
    }

    func trustedIdentity(for context: ContactVerificationContext) throws -> ContactVerificationIdentity? {
        nil
    }

    func status(for context: ContactVerificationContext) throws -> ContactTrustState {
        .unverified
    }

    func removeContact(_ scope: ContactTrustRemovalScope) throws {
        removedScopes.append(scope)
    }
    func removeAll() throws {}
}

private final class SuccessfulContactMutationURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
            url: url,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: APIClientError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct ReplayFixture {
    var clientMessageID: UUID
    var serverMessageID: UUID
    var senderIdentityDigest = Data(repeating: 0x41, count: 32)
    var relayScopeHash = Data(repeating: 0x51, count: 32)
    var localDeviceID: UUID
    var signature = Data(repeating: 0x61, count: 64)

    init() throws {
        clientMessageID = try XCTUnwrap(
            UUID(uuidString: "11111111-2222-4333-8444-555555555555")
        )
        serverMessageID = try XCTUnwrap(
            UUID(uuidString: "66666666-7777-4888-8999-aaaaaaaaaaaa")
        )
        localDeviceID = try XCTUnwrap(
            UUID(uuidString: "feedface-1234-4abc-9def-0123456789ab")
        )
    }
}
