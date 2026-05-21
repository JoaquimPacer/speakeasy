import Foundation

struct PreviewData {
    var currentUser: SpeakeasyUser
    var deviceIdentity: DevicePublicIdentity
    var contacts: [Contact]
    var conversations: [ConversationSummary]
    var messagesByContactID: [UUID: [Message]]

    static var sample: PreviewData {
        let now = Date()
        let currentUserID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        let currentDeviceID = UUID(uuidString: "A0000000-0000-0000-0000-000000000101")!
        let contactID = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!
        let contactDeviceID = UUID(uuidString: "B0000000-0000-0000-0000-000000000101")!

        let user = SpeakeasyUser(
            id: currentUserID,
            username: "joshua",
            createdAt: now.addingTimeInterval(-86_400)
        )

        let deviceIdentity = DevicePublicIdentity(
            deviceID: currentDeviceID,
            encryptionPublicKey: Data(repeating: 2, count: 32),
            signingPublicKey: Data(repeating: 7, count: 32),
            createdAt: now.addingTimeInterval(-86_000)
        )

        let contact = Contact(
            userID: currentUserID,
            contactID: contactID,
            username: "casey",
            nickname: "Casey",
            encryptionPublicKey: Data(repeating: 3, count: 32),
            signingPublicKey: Data(repeating: 8, count: 32),
            createdAt: now.addingTimeInterval(-43_200)
        )

        let sent = Message(
            id: UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!,
            senderID: currentUserID,
            recipientID: contactID,
            envelope: sampleEnvelope(senderDeviceID: currentDeviceID, recipientDeviceID: contactDeviceID, createdAt: now.addingTimeInterval(-3_600)),
            encryptedBlobPath: "messages/C0000000-0000-0000-0000-000000000001.blob",
            localEncryptedPackageURL: nil,
            blobSize: 4_821_120,
            status: .watched,
            deliveredAt: now.addingTimeInterval(-3_300),
            blobDeletedAt: now.addingTimeInterval(-3_200),
            createdAt: now.addingTimeInterval(-3_600),
            expiresAt: now.addingTimeInterval(604_800)
        )

        let received = Message(
            id: UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!,
            senderID: contactID,
            recipientID: currentUserID,
            envelope: sampleEnvelope(senderDeviceID: contactDeviceID, recipientDeviceID: currentDeviceID, createdAt: now.addingTimeInterval(-1_200)),
            encryptedBlobPath: "messages/C0000000-0000-0000-0000-000000000002.blob",
            localEncryptedPackageURL: nil,
            blobSize: 3_342_336,
            status: .delivered,
            deliveredAt: now.addingTimeInterval(-900),
            blobDeletedAt: now.addingTimeInterval(-880),
            createdAt: now.addingTimeInterval(-1_200),
            expiresAt: now.addingTimeInterval(604_800)
        )

        let conversations = [
            ConversationSummary(contact: contact, latestMessage: received, unreadCount: 1)
        ]

        return PreviewData(
            currentUser: user,
            deviceIdentity: deviceIdentity,
            contacts: [contact],
            conversations: conversations,
            messagesByContactID: [contactID: [sent, received]]
        )
    }

    private static func sampleEnvelope(senderDeviceID: UUID, recipientDeviceID: UUID, createdAt: Date) -> MessageEnvelope {
        MessageEnvelope(
            version: 1,
            senderDeviceID: senderDeviceID,
            recipientDeviceID: recipientDeviceID,
            media: EncryptedMediaDescriptor(
                algorithm: EncryptedMediaDescriptor.xChaCha20Poly1305,
                nonce: Data(repeating: 4, count: 24),
                ciphertextHash: Data(repeating: 5, count: 32),
                mimeType: "video/mp4",
                durationSeconds: 42,
                thumbnail: nil
            ),
            contentKey: ContentKeyEnvelope(
                algorithm: ContentKeyEnvelope.sealedBox,
                encryptedContentKey: Data(repeating: 6, count: 48),
                recipientPublicKeyFingerprint: "preview"
            ),
            createdAt: createdAt
        )
    }
}
