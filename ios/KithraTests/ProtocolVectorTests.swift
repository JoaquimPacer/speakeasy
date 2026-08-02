import Foundation
import XCTest
@testable import Kithra

final class ProtocolVectorTests: XCTestCase {
    private var vectors: FixedVectors!

    override func setUpWithError() throws {
        vectors = try FixedVectors.load()
    }

    func testIdentityAndSafetyNumberMatchCanonicalVector() throws {
        let alice = try identity(label: "alice")
        let bob = try identity(label: "bob")
        let identityVectors = vectors.identityVerificationV1
        let aliceVector = try XCTUnwrap(identityVectors.identities.first { $0.label == "alice" })
        let bobVector = try XCTUnwrap(identityVectors.identities.first { $0.label == "bob" })

        XCTAssertEqual(alice.relayOrigin, identityVectors.normalizedRelayOrigin)
        XCTAssertEqual(alice.canonicalBytes.hexString, aliceVector.expected.canonicalIdentityHex)
        XCTAssertEqual(try alice.identityDigest.hexString, aliceVector.expected.identityDigestHex)

        // The fixture deliberately supplies Bob's name in decomposed Unicode form.
        XCTAssertEqual(bob.username, bobVector.inputs.usernameNFC)
        XCTAssertEqual(bob.canonicalBytes.hexString, bobVector.expected.canonicalIdentityHex)
        XCTAssertEqual(try bob.identityDigest.hexString, bobVector.expected.identityDigestHex)

        let aliceFirst = try ContactSafetyNumber(alice, bob)
        let bobFirst = try ContactSafetyNumber(bob, alice)
        XCTAssertEqual(aliceFirst.digest.hexString, identityVectors.expectedPair.pairDigestHex)
        XCTAssertEqual(aliceFirst.digits, identityVectors.expectedPair.safetyNumberDigits)
        XCTAssertEqual(aliceFirst.formattedDigits, identityVectors.expectedPair.safetyNumberDisplay)
        XCTAssertEqual(aliceFirst, bobFirst, "The safety number must be symmetric")
    }

    func testIdentityJSONRoundTripPreservesCanonicalBytes() throws {
        let identity = try identity(label: "bob")
        let encoded = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(ContactVerificationIdentity.self, from: encoded)

        XCTAssertEqual(decoded, identity)
        XCTAssertTrue(decoded.constantTimeEquals(identity))
        XCTAssertEqual(decoded.canonicalBytes, identity.canonicalBytes)
    }

    func testRelayOriginNormalizationAndUsernameNFC() throws {
        let keys = (Data(repeating: 0x11, count: 32), Data(repeating: 0x22, count: 32))
        let userID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        let deviceID = try XCTUnwrap(UUID(uuidString: "01234567-89ab-4cde-8f01-23456789abcd"))

        let defaultPort = try ContactVerificationIdentity(
            relayURL: try XCTUnwrap(URL(string: "https://EXAMPLE.com.:443/a/path?ignored=yes#fragment")),
            userID: userID,
            username: "Cafe\u{301}",
            deviceID: deviceID,
            encryptionPublicKey: keys.0,
            signingPublicKey: keys.1
        )
        XCTAssertEqual(defaultPort.relayOrigin, "https://example.com")
        XCTAssertEqual(defaultPort.username, "Caf\u{e9}")

        let customPort = try ContactVerificationIdentity(
            relayURL: try XCTUnwrap(URL(string: "https://Example.COM:8443/relay")),
            userID: userID,
            username: "Alice",
            deviceID: deviceID,
            encryptionPublicKey: keys.0,
            signingPublicKey: keys.1
        )
        XCTAssertEqual(customPort.relayOrigin, "https://example.com:8443")

        let ipv6 = try ContactVerificationIdentity(
            relayURL: try XCTUnwrap(URL(string: "https://[2001:0db8:0:0:0:0:0:1]:443/")),
            userID: userID,
            username: "Alice",
            deviceID: deviceID,
            encryptionPublicKey: keys.0,
            signingPublicKey: keys.1
        )
        XCTAssertEqual(ipv6.relayOrigin, "https://[2001:db8::1]")

        XCTAssertThrowsError(try ContactVerificationIdentity(
            relayURL: try XCTUnwrap(URL(string: "ftp://example.com")),
            userID: userID,
            username: "Alice",
            deviceID: deviceID,
            encryptionPublicKey: keys.0,
            signingPublicKey: keys.1
        ))
        XCTAssertThrowsError(try ContactVerificationIdentity(
            relayURL: try XCTUnwrap(URL(string: "https://user@example.com")),
            userID: userID,
            username: "Alice",
            deviceID: deviceID,
            encryptionPublicKey: keys.0,
            signingPublicKey: keys.1
        ))
    }

    func testSignedQRCodeMatchesVectorAndValidatesExpectedPair() throws {
        let alice = try identity(label: "alice")
        let bob = try identity(label: "bob")
        let qrVector = vectors.identityVerificationV1.signedQR

        let signingBytes = try ContactVerificationQRPayload.signingBytes(
            presenterIdentity: alice,
            expectedPeerIdentity: bob
        )
        XCTAssertEqual(signingBytes.hexString, qrVector.unsignedBytesHex)

        let payload = try ContactVerificationQRPayload.parse(qrVector.encodedText)
        XCTAssertEqual(payload.presenterIdentity, alice)
        XCTAssertEqual(payload.pairDigest.hexString, vectors.identityVerificationV1.expectedPair.pairDigestHex)
        XCTAssertEqual(payload.signature.hexString, qrVector.signatureHex)
        XCTAssertEqual(payload.encodedString, qrVector.encodedText)

        let validated = try payload.validate(scannedBy: bob, expectedPresenter: alice)
        XCTAssertEqual(validated.digits, vectors.identityVerificationV1.expectedPair.safetyNumberDigits)
    }

    func testSignedQRCodeRejectsTamperingAndWrongPeer() throws {
        let alice = try identity(label: "alice")
        let bob = try identity(label: "bob")
        let encoded = vectors.identityVerificationV1.signedQR.encodedText
        var tampered = encoded
        let finalIndex = tampered.index(before: tampered.endIndex)
        tampered.replaceSubrange(finalIndex...finalIndex, with: tampered[finalIndex] == "A" ? "B" : "A")
        XCTAssertThrowsError(try ContactVerificationQRPayload.parse(tampered))

        let payload = try ContactVerificationQRPayload.parse(encoded)
        XCTAssertThrowsError(try payload.validate(scannedBy: bob, expectedPresenter: bob))

        let wrongPeer = try ContactVerificationIdentity(
            relayURL: try XCTUnwrap(URL(string: vectors.identityVerificationV1.relayURLInput)),
            userID: try XCTUnwrap(UUID(uuidString: "99999999-8888-4777-8666-555555555555")),
            username: "Mallory",
            deviceID: try XCTUnwrap(UUID(uuidString: "44444444-3333-4222-8111-000000000000")),
            encryptionPublicKey: Data(repeating: 0x33, count: 32),
            signingPublicKey: Data(repeating: 0x44, count: 32)
        )
        XCTAssertThrowsError(try payload.validate(scannedBy: wrongPeer, expectedPresenter: alice))
    }

    func testBothMessageTranscriptsAndSignaturesMatchCanonicalVectors() throws {
        let authenticator = MessageEnvelopeAuthenticator()
        let alice = try identity(label: "alice")

        for messageCase in vectors.messageEnvelopeV2.cases {
            let senderUserID = try XCTUnwrap(UUID(uuidString: messageCase.authenticatedContext.senderUserID))
            let recipientUserID = try XCTUnwrap(UUID(uuidString: messageCase.authenticatedContext.recipientUserID))
            let transcript = try authenticator.makeTranscript(
                envelope: messageCase.envelope,
                senderUserID: senderUserID,
                recipientUserID: recipientUserID
            )
            XCTAssertEqual(
                transcript.hexString,
                messageCase.expected.canonicalTranscriptHex,
                "Canonical transcript mismatch for \(messageCase.name)"
            )

            let senderDigest = try XCTUnwrap(messageCase.envelope.senderIdentityDigest)
            let recipientDigest = try XCTUnwrap(messageCase.envelope.recipientIdentityDigest)
            let message = makeMessage(
                envelope: messageCase.envelope,
                senderUserID: senderUserID,
                recipientUserID: recipientUserID
            )
            XCTAssertNoThrow(try authenticator.verify(
                message: message,
                expectedSenderUserID: senderUserID,
                expectedSenderDeviceID: messageCase.envelope.senderDeviceID,
                expectedSenderIdentityDigest: senderDigest,
                expectedSenderSigningPublicKey: alice.signingPublicKey,
                expectedRecipientUserID: recipientUserID,
                expectedRecipientDeviceID: messageCase.envelope.recipientDeviceID,
                expectedRecipientIdentityDigest: recipientDigest
            ), "Signature verification failed for \(messageCase.name)")
        }
    }

    func testMessageEnvelopeJSONRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for messageCase in vectors.messageEnvelopeV2.cases {
            let encoded = try encoder.encode(messageCase.envelope)
            let decoded = try decoder.decode(MessageEnvelope.self, from: encoded)
            XCTAssertEqual(decoded, messageCase.envelope, "JSON round trip failed for \(messageCase.name)")
        }
    }

    func testMessageEnvelopeJSONRejectsUnknownNestedFields() throws {
        let messageCase = try XCTUnwrap(vectors.messageEnvelopeV2.cases.first {
            $0.name == "all-optionals-present"
        })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(messageCase.envelope)

        func assertRejected(
            _ mutate: (inout [String: Any]) throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            try mutate(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(
                try decoder.decode(MessageEnvelope.self, from: data),
                file: file,
                line: line
            )
        }

        try assertRejected { $0["relayExtension"] = true }
        try assertRejected { envelope in
            var media = try XCTUnwrap(envelope["media"] as? [String: Any])
            media["relayExtension"] = true
            envelope["media"] = media
        }
        try assertRejected { envelope in
            var contentKey = try XCTUnwrap(envelope["contentKey"] as? [String: Any])
            contentKey["relayExtension"] = true
            envelope["contentKey"] = contentKey
        }
        try assertRejected { envelope in
            var senderContentKey = try XCTUnwrap(
                envelope["senderContentKey"] as? [String: Any]
            )
            senderContentKey["relayExtension"] = true
            envelope["senderContentKey"] = senderContentKey
        }
        try assertRejected { envelope in
            var media = try XCTUnwrap(envelope["media"] as? [String: Any])
            var thumbnail = try XCTUnwrap(media["thumbnail"] as? [String: Any])
            thumbnail["relayExtension"] = true
            media["thumbnail"] = thumbnail
            envelope["media"] = media
        }
    }

    func testMessageWireEncodingExcludesLocalRuntimeURLs() throws {
        let messageCase = try XCTUnwrap(vectors.messageEnvelopeV2.cases.first)
        let senderUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.senderUserID
        ))
        let recipientUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.recipientUserID
        ))
        var message = makeMessage(
            envelope: messageCase.envelope,
            senderUserID: senderUserID,
            recipientUserID: recipientUserID
        )
        message.localEncryptedPackageURL = try XCTUnwrap(URL(string: "file:///private/local-message.blob"))
        message.localThumbnailURL = try XCTUnwrap(URL(string: "https://tracker.example/thumbnail.jpg"))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(message)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(object["localEncryptedPackageURL"])
        XCTAssertNil(object["localThumbnailURL"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Message.self, from: encoded)
        XCTAssertNil(decoded.localEncryptedPackageURL)
        XCTAssertNil(decoded.localThumbnailURL)
    }

    func testMessageWireRejectsInjectedLocalRuntimeURLs() throws {
        let messageCase = try XCTUnwrap(vectors.messageEnvelopeV2.cases.first)
        let senderUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.senderUserID
        ))
        let recipientUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.recipientUserID
        ))
        let message = makeMessage(
            envelope: messageCase.envelope,
            senderUserID: senderUserID,
            recipientUserID: recipientUserID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(message)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for (field, value) in [
            ("localEncryptedPackageURL", "file:///private/relay-selected.blob"),
            ("localThumbnailURL", "https://tracker.example/relay-selected.jpg")
        ] {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object[field] = value
            let injected = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(
                try decoder.decode(Message.self, from: injected),
                "Expected relay-supplied \(field) to be rejected"
            )
        }
    }

    func testMessageTranscriptRejectsInvalidAlgorithmsAndLengths() throws {
        let authenticator = MessageEnvelopeAuthenticator()
        let absentCase = try XCTUnwrap(vectors.messageEnvelopeV2.cases.first {
            $0.name == "required-fields-optionals-absent"
        })
        let presentCase = try XCTUnwrap(vectors.messageEnvelopeV2.cases.first {
            $0.name == "all-optionals-present"
        })
        let senderUserID = try XCTUnwrap(UUID(uuidString: absentCase.authenticatedContext.senderUserID))
        let recipientUserID = try XCTUnwrap(UUID(uuidString: absentCase.authenticatedContext.recipientUserID))

        func assertRejected(
            _ original: MessageEnvelope = absentCase.envelope,
            file: StaticString = #filePath,
            line: UInt = #line,
            mutate: (inout MessageEnvelope) -> Void
        ) {
            var envelope = original
            mutate(&envelope)
            XCTAssertThrowsError(
                try authenticator.makeTranscript(
                    envelope: envelope,
                    senderUserID: senderUserID,
                    recipientUserID: recipientUserID
                ),
                file: file,
                line: line
            )
        }

        assertRejected { $0.authenticationAlgorithm = "ed25519" }
        assertRejected { $0.media.algorithm = "AES-GCM" }
        assertRejected { $0.media.nonce = Data(repeating: 0, count: 23) }
        assertRejected { $0.media.nonce = Data(repeating: 0, count: 25) }
        assertRejected { $0.media.ciphertextHash = Data(repeating: 0, count: 31) }
        assertRejected { $0.media.mimeType = "" }
        assertRejected { $0.media.mimeType = String(repeating: "m", count: 256) }
        assertRejected { $0.media.mimeType = "video/mp4\n" }
        assertRejected { $0.senderIdentityDigest = Data(repeating: 0, count: 33) }
        assertRejected { $0.contentKey.algorithm = "crypto_box" }
        assertRejected { $0.contentKey.encryptedContentKey = Data(repeating: 0, count: 79) }
        assertRejected { $0.contentKey.encryptedContentKey = Data(repeating: 0, count: 81) }
        assertRejected { $0.contentKey.recipientPublicKeyFingerprint = "" }
        assertRejected {
            $0.contentKey.recipientPublicKeyFingerprint = String(repeating: "f", count: 257)
        }
        assertRejected(presentCase.envelope) { $0.senderContentKey?.algorithm = "crypto_box" }
        assertRejected(presentCase.envelope) { $0.senderContentKey?.encryptedContentKey = Data(repeating: 0, count: 79) }
        assertRejected(presentCase.envelope) { $0.media.thumbnail?.algorithm = "AES-GCM" }
        assertRejected(presentCase.envelope) { $0.media.thumbnail?.nonce = Data(repeating: 0, count: 25) }
        assertRejected(presentCase.envelope) { $0.media.thumbnail?.ciphertextHash = Data(repeating: 0, count: 31) }
        assertRejected(presentCase.envelope) { $0.media.thumbnail?.encryptedBlobPath = "" }
        assertRejected(presentCase.envelope) {
            $0.media.thumbnail?.encryptedBlobPath = String(repeating: "p", count: 2_049)
        }
        assertRejected { $0.createdAt = $0.createdAt.addingTimeInterval(0.5) }
    }

    func testMessageSignatureRejectsAuthenticatedFieldTampering() throws {
        let authenticator = MessageEnvelopeAuthenticator()
        let messageCase = try XCTUnwrap(vectors.messageEnvelopeV2.cases.first)
        let senderUserID = try XCTUnwrap(UUID(uuidString: messageCase.authenticatedContext.senderUserID))
        let recipientUserID = try XCTUnwrap(UUID(uuidString: messageCase.authenticatedContext.recipientUserID))
        let alice = try identity(label: "alice")
        var tamperedEnvelope = messageCase.envelope
        tamperedEnvelope.media.mimeType = "video/quicktime"
        let message = makeMessage(
            envelope: tamperedEnvelope,
            senderUserID: senderUserID,
            recipientUserID: recipientUserID
        )

        XCTAssertThrowsError(try authenticator.verify(
            message: message,
            expectedSenderUserID: senderUserID,
            expectedSenderDeviceID: tamperedEnvelope.senderDeviceID,
            expectedSenderIdentityDigest: try XCTUnwrap(tamperedEnvelope.senderIdentityDigest),
            expectedSenderSigningPublicKey: alice.signingPublicKey,
            expectedRecipientUserID: recipientUserID,
            expectedRecipientDeviceID: tamperedEnvelope.recipientDeviceID,
            expectedRecipientIdentityDigest: try XCTUnwrap(tamperedEnvelope.recipientIdentityDigest)
        )) { error in
            guard case MessageEnvelopeAuthenticationError.invalidSignature = error else {
                return XCTFail("Expected invalidSignature, received \(error)")
            }
        }
    }

    func testMessageVerificationRejectsRelayMetadataRelabelingAndDowngrade() throws {
        let authenticator = MessageEnvelopeAuthenticator()
        let messageCase = try XCTUnwrap(vectors.messageEnvelopeV2.cases.first)
        let senderUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.senderUserID
        ))
        let recipientUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.recipientUserID
        ))
        let alice = try identity(label: "alice")
        let senderDigest = try XCTUnwrap(messageCase.envelope.senderIdentityDigest)
        let recipientDigest = try XCTUnwrap(messageCase.envelope.recipientIdentityDigest)
        let original = makeMessage(
            envelope: messageCase.envelope,
            senderUserID: senderUserID,
            recipientUserID: recipientUserID
        )

        func verify(_ message: Message) throws {
            try authenticator.verify(
                message: message,
                expectedSenderUserID: senderUserID,
                expectedSenderDeviceID: messageCase.envelope.senderDeviceID,
                expectedSenderIdentityDigest: senderDigest,
                expectedSenderSigningPublicKey: alice.signingPublicKey,
                expectedRecipientUserID: recipientUserID,
                expectedRecipientDeviceID: messageCase.envelope.recipientDeviceID,
                expectedRecipientIdentityDigest: recipientDigest
            )
        }

        XCTAssertNoThrow(try verify(original))

        var relabeledSender = original
        relabeledSender.senderID = UUID()
        XCTAssertThrowsError(try verify(relabeledSender)) { error in
            guard case MessageEnvelopeAuthenticationError.unexpectedSender = error else {
                return XCTFail("Expected unexpectedSender, received \(error)")
            }
        }

        var relabeledRecipient = original
        relabeledRecipient.recipientID = UUID()
        XCTAssertThrowsError(try verify(relabeledRecipient)) { error in
            guard case MessageEnvelopeAuthenticationError.unexpectedRecipient = error else {
                return XCTFail("Expected unexpectedRecipient, received \(error)")
            }
        }

        var relabeledDevice = original
        relabeledDevice.recipientDeviceID = UUID()
        XCTAssertThrowsError(try verify(relabeledDevice)) { error in
            guard case MessageEnvelopeAuthenticationError.unexpectedRecipient = error else {
                return XCTFail("Expected unexpectedRecipient, received \(error)")
            }
        }

        var downgraded = original
        downgraded.envelope.version = 1
        XCTAssertThrowsError(try verify(downgraded)) { error in
            guard case MessageEnvelopeAuthenticationError.unsupportedVersion = error else {
                return XCTFail("Expected unsupportedVersion, received \(error)")
            }
        }
    }

    func testMessageRelationshipRequiresOneExactLocalDirection() throws {
        let messageCase = try XCTUnwrap(vectors.messageEnvelopeV2.cases.first)
        let senderUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.senderUserID
        ))
        let recipientUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.recipientUserID
        ))
        let original = makeMessage(
            envelope: messageCase.envelope,
            senderUserID: senderUserID,
            recipientUserID: recipientUserID
        )

        XCTAssertEqual(try MessageRelationshipResolver.resolve(
            message: original,
            localUserID: recipientUserID,
            localDeviceID: messageCase.envelope.recipientDeviceID
        ), .incoming)
        XCTAssertEqual(try MessageRelationshipResolver.resolve(
            message: original,
            localUserID: senderUserID,
            localDeviceID: messageCase.envelope.senderDeviceID
        ), .outgoing)

        var neitherDirection = original
        neitherDirection.recipientID = UUID()
        XCTAssertThrowsError(try MessageRelationshipResolver.resolve(
            message: neitherDirection,
            localUserID: recipientUserID,
            localDeviceID: messageCase.envelope.recipientDeviceID
        ))

        var ambiguousDirection = original
        ambiguousDirection.senderID = recipientUserID
        ambiguousDirection.senderDeviceID = messageCase.envelope.recipientDeviceID
        XCTAssertThrowsError(try MessageRelationshipResolver.resolve(
            message: ambiguousDirection,
            localUserID: recipientUserID,
            localDeviceID: messageCase.envelope.recipientDeviceID
        ))
    }

    @MainActor
    func testOutgoingHistoryHydratesByAuthenticatedClientMessageID() async throws {
        let alice = try identity(label: "alice")
        let bob = try identity(label: "bob")
        let messageCase = try XCTUnwrap(vectors.messageEnvelopeV2.cases.first)
        let senderUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.senderUserID
        ))
        let recipientUserID = try XCTUnwrap(UUID(
            uuidString: messageCase.authenticatedContext.recipientUserID
        ))
        let clientMessageID = try XCTUnwrap(messageCase.envelope.clientMessageID)
        let message = makeMessage(
            envelope: messageCase.envelope,
            senderUserID: senderUserID,
            recipientUserID: recipientUserID,
            id: UUID()
        )

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("KithraOutgoingHydrationTests-\(UUID().uuidString)", isDirectory: true)
        let tempRoot = root.appendingPathComponent("Temp", isDirectory: true)
        let localMediaRoot = root.appendingPathComponent("Local", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("outgoing.blob")
        try Data("durable outgoing ciphertext".utf8).write(to: sourceURL)
        let pipeline = DefaultMediaPipeline(
            fileManager: fileManager,
            tempRoot: tempRoot,
            localMediaRoot: localMediaRoot
        )
        let durableURL = try await pipeline.persistOutgoingPackage(
            sourceURL,
            clientMessageID: clientMessageID
        )

        let now = messageCase.envelope.createdAt
        let state = AppState(
            relayBaseURL: try XCTUnwrap(URL(string: vectors.identityVerificationV1.relayURLInput)),
            mediaPipeline: pipeline,
            contactTrustStore: AlwaysVerifiedContactTrustStore(),
            seedPreviewData: true
        )
        state.currentUser = SpeakeasyUser(
            id: alice.userID,
            username: alice.username,
            createdAt: now
        )
        state.deviceIdentity = DevicePublicIdentity(
            deviceID: alice.deviceID,
            encryptionPublicKey: alice.encryptionPublicKey,
            signingPublicKey: alice.signingPublicKey,
            createdAt: now
        )
        state.contacts = [Contact(
            userID: alice.userID,
            contactID: bob.userID,
            deviceID: bob.deviceID,
            username: bob.username,
            nickname: nil,
            encryptionPublicKey: bob.encryptionPublicKey,
            signingPublicKey: bob.signingPublicKey,
            createdAt: now
        )]

        let hydrated = await state.hydrateLocalMedia(on: [message])
        XCTAssertEqual(try XCTUnwrap(hydrated.first).localEncryptedPackageURL, durableURL)

        // Copying an existing signature/client ID into changed relay metadata
        // must not select the local sender package before authentication.
        var relabeled = message
        relabeled.recipientID = UUID()
        let rejected = await state.hydrateLocalMedia(on: [relabeled])
        XCTAssertNil(try XCTUnwrap(rejected.first).localEncryptedPackageURL)
        XCTAssertNil(try XCTUnwrap(rejected.first).localThumbnailURL)
    }

    private func identity(label: String) throws -> ContactVerificationIdentity {
        let vector = try XCTUnwrap(vectors.identityVerificationV1.identities.first { $0.label == label })
        return try ContactVerificationIdentity(
            relayURL: try XCTUnwrap(URL(string: vectors.identityVerificationV1.relayURLInput)),
            userID: try XCTUnwrap(UUID(uuidString: vector.inputs.userID)),
            username: vector.inputs.usernameBeforeNFC,
            deviceID: try XCTUnwrap(UUID(uuidString: vector.inputs.deviceID)),
            encryptionPublicKey: try XCTUnwrap(Data(base64Encoded: vector.expected.x25519PublicKeyBase64)),
            signingPublicKey: try XCTUnwrap(Data(base64Encoded: vector.expected.ed25519PublicKeyBase64))
        )
    }

    private func makeMessage(
        envelope: MessageEnvelope,
        senderUserID: UUID,
        recipientUserID: UUID,
        id: UUID = UUID()
    ) -> Message {
        Message(
            id: id,
            senderID: senderUserID,
            senderDeviceID: envelope.senderDeviceID,
            recipientID: recipientUserID,
            recipientDeviceID: envelope.recipientDeviceID,
            envelope: envelope,
            encryptedBlobPath: "messages/fixture.blob",
            localEncryptedPackageURL: nil,
            blobSize: 64,
            status: .sent,
            deliveredAt: nil,
            blobDeletedAt: nil,
            createdAt: envelope.createdAt,
            expiresAt: envelope.createdAt.addingTimeInterval(86_400)
        )
    }
}

private struct FixedVectors: Decodable {
    let identityVerificationV1: IdentityVectors
    let messageEnvelopeV2: MessageVectors

    static func load() throws -> FixedVectors {
        guard let url = Bundle(for: ProtocolVectorTests.self).url(
            forResource: "kithra-identity-v1-message-v2",
            withExtension: "json"
        ) else {
            throw FixtureError.missingResource
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FixedVectors.self, from: Data(contentsOf: url))
    }
}

private struct IdentityVectors: Decodable {
    let relayURLInput: String
    let normalizedRelayOrigin: String
    let identities: [IdentityVector]
    let expectedPair: PairVector
    let signedQR: QRVector
}

private struct IdentityVector: Decodable {
    let label: String
    let inputs: IdentityInputs
    let expected: IdentityExpected
}

private struct IdentityInputs: Decodable {
    let userID: String
    let deviceID: String
    let usernameBeforeNFC: String
    let usernameNFC: String
}

private struct IdentityExpected: Decodable {
    let x25519PublicKeyBase64: String
    let ed25519PublicKeyBase64: String
    let canonicalIdentityHex: String
    let identityDigestHex: String
}

private struct PairVector: Decodable {
    let pairDigestHex: String
    let safetyNumberDigits: String
    let safetyNumberDisplay: String
}

private struct QRVector: Decodable {
    let unsignedBytesHex: String
    let signatureHex: String
    let encodedText: String
}

private struct MessageVectors: Decodable {
    let cases: [MessageVector]
}

private struct MessageVector: Decodable {
    let name: String
    let authenticatedContext: AuthenticatedContext
    let envelope: MessageEnvelope
    let expected: MessageExpected
}

private struct AuthenticatedContext: Decodable {
    let senderUserID: String
    let recipientUserID: String
}

private struct MessageExpected: Decodable {
    let canonicalTranscriptHex: String
}

private enum FixtureError: Error {
    case missingResource
}

private final class AlwaysVerifiedContactTrustStore: ContactTrustStoring {
    func observe(_ context: ContactVerificationContext) throws -> ContactTrustAssessment {
        ContactTrustAssessment(
            state: .verified,
            candidateIdentity: context.remoteIdentity,
            trustedIdentity: context.remoteIdentity,
            verificationMethod: .safetyNumberComparison,
            verifiedAt: Date()
        )
    }

    func recordVerification(
        _ context: ContactVerificationContext,
        method: ContactVerificationMethod
    ) throws -> ContactTrustAssessment {
        try observe(context)
    }

    func trustedIdentity(
        for context: ContactVerificationContext
    ) throws -> ContactVerificationIdentity? {
        context.remoteIdentity
    }

    func status(for context: ContactVerificationContext) throws -> ContactTrustState {
        .verified
    }

    func removeContact(_ scope: ContactTrustRemovalScope) throws {}
    func removeAll() throws {}
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
