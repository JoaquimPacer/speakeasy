import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let persistedSessionKey = "speakeasy.authSession.v1"
    private static let installMarkerKey = "speakeasy.installMarker.v1"
    private static let localDefaultRelayURL = URL(string: "http://localhost:8080")!

    @Published var relayBaseURLString: String
    @Published var currentUser: SpeakeasyUser?
    @Published var deviceIdentity: DevicePublicIdentity?
    @Published var contacts: [Contact]
    @Published var contactTrustAssessments: [UUID: ContactTrustAssessment]
    @Published var conversations: [ConversationSummary]
    @Published var messagesByContactID: [UUID: [Message]]
    @Published var lastInviteCode: String?
    @Published var lastErrorMessage: String?
    @Published var activePlaybackFile: PlaybackTempFile?
    @Published var isWorking = false

    let apiClient: SpeakeasyAPIClient
    let keyManager: DeviceKeyManaging
    let mediaPipeline: MediaPipelining
    let contactTrustStore: ContactTrustStoring
    let messageReplayStore: MessageReplayStoring
    private let messageAuthenticator: MessageEnvelopeAuthenticator
    private var isRefreshingQuietly = false
    private var localEncryptedPackageURLs: [LocalEncryptedMediaIdentifier: URL] = [:]
    private var localThumbnailURLs: [AuthenticatedThumbnailIdentifier: URL] = [:]
    private var remotePollingTask: Task<Void, Never>?
    private var playbackCleanupTask: Task<Void, Never>?
    private var requiresFreshInstallKeychainReset: Bool
    private var activeIncomingReceiptOperations: Set<IncomingReceiptOperationKey> = []
    private var isClearingLocalAccountState = false
    private var accountStateGeneration: UInt64 = 0

    init(
        relayBaseURL: URL? = nil,
        apiClient: SpeakeasyAPIClient? = nil,
        keyManager: DeviceKeyManaging = KeychainDeviceKeyManager(),
        mediaPipeline: MediaPipelining = DefaultMediaPipeline(),
        contactTrustStore: ContactTrustStoring = KeychainContactTrustStore(),
        messageReplayStore: MessageReplayStoring = KeychainMessageReplayStore(),
        messageAuthenticator: MessageEnvelopeAuthenticator = MessageEnvelopeAuthenticator(),
        seedPreviewData: Bool = true
    ) {
        let effectiveRelayBaseURL = relayBaseURL ?? Self.bundledDefaultRelayURL
        self.relayBaseURLString = effectiveRelayBaseURL.absoluteString
        self.apiClient = apiClient ?? SpeakeasyAPIClient(configuration: APIConfiguration(baseURL: effectiveRelayBaseURL))
        self.keyManager = keyManager
        self.mediaPipeline = mediaPipeline
        self.contactTrustStore = contactTrustStore
        self.messageReplayStore = messageReplayStore
        self.messageAuthenticator = messageAuthenticator
        let persistedSession = seedPreviewData ? nil : Self.loadPersistedSession()
        let hasInstallMarker = UserDefaults.standard.object(
            forKey: Self.installMarkerKey
        ) != nil
        self.requiresFreshInstallKeychainReset = !seedPreviewData &&
            !hasInstallMarker &&
            persistedSession == nil
        if !seedPreviewData && !self.requiresFreshInstallKeychainReset {
            UserDefaults.standard.set(true, forKey: Self.installMarkerKey)
        }

        if seedPreviewData {
            let preview = PreviewData.sample
            self.currentUser = preview.currentUser
            self.deviceIdentity = preview.deviceIdentity
            self.contacts = preview.contacts
            self.contactTrustAssessments = [:]
            self.conversations = preview.conversations
            self.messagesByContactID = preview.messagesByContactID
            self.lastInviteCode = nil
            self.lastErrorMessage = nil
            self.activePlaybackFile = nil
        } else {
            self.currentUser = persistedSession?.session.user
            self.deviceIdentity = nil
            self.contacts = []
            self.contactTrustAssessments = [:]
            self.conversations = []
            self.messagesByContactID = [:]
            self.lastInviteCode = nil
            self.lastErrorMessage = nil
            self.activePlaybackFile = nil
        }

        if let persistedSession {
            self.relayBaseURLString = persistedSession.relayBaseURLString
            Task {
                await restore(persistedSession)
            }
        }
    }

    deinit {
        remotePollingTask?.cancel()
        playbackCleanupTask?.cancel()
    }

    func messages(for contact: Contact) -> [Message] {
        messagesByContactID[contact.contactID, default: []]
            .sorted { $0.createdAt < $1.createdAt }
    }

    func trustState(for contact: Contact) -> ContactTrustState {
        contactTrustAssessments[contact.contactID]?.state ?? .unverified
    }

    func trustAssessment(for contact: Contact) -> ContactTrustAssessment? {
        contactTrustAssessments[contact.contactID]
    }

    func safetyNumber(for contact: Contact) -> ContactSafetyNumber? {
        guard let context = try? makeVerificationContext(for: contact) else {
            return nil
        }
        return try? context.safetyNumber
    }

    func contactVerificationQRCode(for contact: Contact) async -> String? {
        var encodedPayload: String?
        await perform {
            let context = try makeVerificationContext(for: contact)
            let signingBytes = try ContactVerificationQRPayload.signingBytes(
                presenterIdentity: context.localIdentity,
                expectedPeerIdentity: context.remoteIdentity
            )
            let signature = try await keyManager.signContactVerificationTranscript(signingBytes)
            let currentContext = try makeVerificationContext(for: contact)
            guard currentContext.localIdentity.constantTimeEquals(context.localIdentity),
                  currentContext.remoteIdentity.constantTimeEquals(context.remoteIdentity) else {
                throw ContactMessagingSecurityError.identityChangedDuringVerification
            }
            encodedPayload = try ContactVerificationQRPayload(
                presenterIdentity: context.localIdentity,
                expectedPeerIdentity: context.remoteIdentity,
                signature: signature
            ).encodedString
        }
        return encodedPayload
    }

    @discardableResult
    func verifyContact(_ contact: Contact, scannedQRCode: String) async -> Bool {
        await perform {
            let context = try makeVerificationContext(for: contact)
            let payload = try ContactVerificationQRPayload.parse(scannedQRCode)
            _ = try payload.validate(
                scannedBy: context.localIdentity,
                expectedPresenter: context.remoteIdentity
            )
            let assessment = try contactTrustStore.recordVerification(context, method: .qrCode)
            contactTrustAssessments[contact.contactID] = assessment
        }
    }

    @discardableResult
    func confirmSafetyNumberComparison(
        for contact: Contact,
        expectedSafetyDigest: Data
    ) async -> Bool {
        await perform {
            let context = try makeVerificationContext(for: contact)
            let currentSafetyNumber = try context.safetyNumber
            guard currentSafetyNumber.constantTimeMatches(digest: expectedSafetyDigest) else {
                throw ContactVerificationError.safetyNumberMismatch
            }
            let assessment = try contactTrustStore.recordVerification(
                context,
                method: .safetyNumberComparison
            )
            contactTrustAssessments[contact.contactID] = assessment
        }
    }

    func updateRelayBaseURL(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedText),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https",
              url.host != nil else {
            lastErrorMessage = "Enter a valid relay URL."
            return
        }
        if currentUser != nil, trimmedText != relayBaseURLString {
            lastErrorMessage = "Reset local registration before switching relays so account keys, trust pins, and replay history cannot cross relay scopes."
            return
        }

        relayBaseURLString = trimmedText
        lastErrorMessage = nil
        contactTrustAssessments = [:]
        await apiClient.updateBaseURL(url)
        persistRelayBaseURLString()
    }

    func prepareLocalIdentity() async {
        await perform {
            try await clearResidualKeychainAfterFreshInstallIfNeeded()
            deviceIdentity = try await keyManager.loadOrCreateIdentity()
        }
    }

    func register(username: String) async {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            lastErrorMessage = "Choose a username before registering."
            return
        }

        await perform {
            try await clearResidualKeychainAfterFreshInstallIfNeeded()
            let identity = try await keyManager.loadOrCreateIdentity()
            guard identity.deviceID == nil else {
                throw ContactMessagingSecurityError.localIdentityAlreadyBound
            }
            let session = try await apiClient.register(
                username: trimmedUsername,
                deviceName: "Kithra iOS",
                encryptionPublicKey: identity.encryptionPublicKey,
                signingPublicKey: identity.signingPublicKey
            )

            try validateRegistrationSession(
                session,
                requestedUsername: trimmedUsername,
                localIdentity: identity
            )
            let registeredIdentity = try await keyManager.bindRegisteredDeviceID(session.device.id)
            try validateLocalIdentity(registeredIdentity, against: session)

            await apiClient.setBearerToken(session.bearerToken)
            currentUser = session.user
            deviceIdentity = registeredIdentity
            persist(session: session)
            contacts = []
            conversations = []
            messagesByContactID = [:]
            try await refreshLocalState()
        }
    }

    func createContactInvite() async {
        await perform {
            let invite = try await apiClient.createContactInvite()
            lastInviteCode = invite.code
        }
    }

    @discardableResult
    func acceptContactInvite(code: String) async -> Bool {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            lastErrorMessage = "Enter an invite code before accepting."
            return false
        }

        return await perform {
            let contact = try await apiClient.acceptContactInvite(code: trimmedCode)
            upsert(contact)
            try await refreshLocalState()
        }
    }

    func deleteContact(_ contact: Contact) async {
        await perform {
            let trustRemovalScope = try makeTrustRemovalScope(for: contact)
            try contactTrustStore.removeContact(trustRemovalScope)
            contactTrustAssessments[contact.contactID] = nil
            try await apiClient.deleteContact(contactID: contact.contactID)

            // Contact verification can run while the relay request is suspended.
            // Sweep the same stable scope again before removing the local contact
            // so a pin created during that window cannot survive deletion.
            defer { removeContactLocally(contactID: contact.contactID) }
            try contactTrustStore.removeContact(trustRemovalScope)
        }
    }

    func blockContact(_ contact: Contact) async {
        await perform {
            let trustRemovalScope = try makeTrustRemovalScope(for: contact)
            try contactTrustStore.removeContact(trustRemovalScope)
            contactTrustAssessments[contact.contactID] = nil
            try await apiClient.blockContact(contactID: contact.contactID)

            // Mirror deletion's post-response sweep. No actor suspension occurs
            // between this purge and making the contact unavailable locally.
            defer { removeContactLocally(contactID: contact.contactID) }
            try contactTrustStore.removeContact(trustRemovalScope)
        }
    }

    func reportContact(_ contact: Contact) async {
        await perform {
            try await apiClient.reportContact(
                contactID: contact.contactID,
                reason: "contact",
                details: "Reported from the iOS contact menu."
            )
        }
    }

    func refresh() async {
        await perform {
            try await refreshLocalState()
        }
    }

    func refreshQuietly() async {
        guard currentUser != nil, !isWorking, !isRefreshingQuietly else {
            return
        }

        isRefreshingQuietly = true
        defer { isRefreshingQuietly = false }

        do {
            try await refreshLocalState()
        } catch {
            // Background polling should not interrupt capture or playback with transient network errors.
        }
    }

    func startRemotePolling(every intervalNanoseconds: UInt64 = 2_000_000_000) {
        guard currentUser != nil else {
            stopRemotePolling()
            return
        }
        guard remotePollingTask == nil else {
            return
        }

        remotePollingTask = Task { [weak self] in
            await self?.refreshQuietly()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard !Task.isCancelled else {
                    break
                }
                await self?.refreshQuietly()
            }
        }
    }

    func stopRemotePolling() {
        remotePollingTask?.cancel()
        remotePollingTask = nil
    }

    func deleteAccount() async {
        await perform {
            try await apiClient.deleteAccount()
            await clearLocalAccountState()
        }
    }

    func resetLocalRegistration() async {
        await perform {
            await clearLocalAccountState()
        }
    }

    func discardActivePlaybackFile() async {
        playbackCleanupTask?.cancel()
        playbackCleanupTask = nil
        guard let activePlaybackFile else {
            return
        }

        self.activePlaybackFile = nil
        await mediaPipeline.cleanupTemporaryFiles([activePlaybackFile.url])
    }

    func sendVideo(rawVideoURL: URL, quality: DeliveryVideoQuality, to contact: Contact) async {
        await perform {
            guard let currentUser, let senderDeviceID = deviceIdentity?.deviceID else {
                throw DeviceKeyManagerError.identityNotFound
            }
            let compressedVideoURL = try await mediaPipeline.compressForDelivery(
                rawVideoURL: rawVideoURL,
                quality: quality
            )
            var generatedPackage: EncryptedMediaPackage?
            var durableLocalPackageURL: URL?
            var generatedThumbnailURL: URL?
            var uploadStarted = false

            do {
                // Compression crosses an async suspension point. Re-resolve the contact
                // and its pin immediately before encrypting.
                let initialVerification = try verifiedRecipient(for: contact.contactID)
                let package = try await mediaPipeline.encryptPackage(
                    compressedVideoURL: compressedVideoURL,
                    thumbnailURL: nil,
                    recipientEncryptionPublicKey: initialVerification.recipient.encryptionPublicKey,
                    senderUserID: currentUser.id,
                    senderDeviceID: senderDeviceID,
                    senderIdentityDigest: try initialVerification.context.localIdentity.identityDigest,
                    recipientUserID: initialVerification.recipient.userID,
                    recipientDeviceID: initialVerification.recipient.deviceID,
                    recipientIdentityDigest: try initialVerification.recipient.identityDigest
                )
                generatedPackage = package

                // Encryption is also asynchronous. Require the exact same local and
                // remote identities immediately before upload; otherwise discard the
                // ciphertext and make the user verify the new identity first.
                guard self.currentUser?.id == currentUser.id,
                      deviceIdentity?.deviceID == senderDeviceID else {
                    throw ContactMessagingSecurityError.localIdentityMismatch
                }
                let finalVerification = try verifiedRecipient(for: contact.contactID)
                guard finalVerification.recipient.constantTimeEquals(initialVerification.recipient),
                      finalVerification.context.localIdentity.constantTimeEquals(
                          initialVerification.context.localIdentity
                      ) else {
                    throw ContactMessagingSecurityError.identityChangedDuringSend
                }

                guard let clientMessageID = package.envelope.clientMessageID,
                      clientMessageID == package.id,
                      let envelopeSignature = package.envelope.signature else {
                    throw MessageEnvelopeAuthenticationError.missingField(
                        "signed client message ID or signature"
                    )
                }
                let encryptedIdentifier = LocalEncryptedMediaIdentifier
                    .outgoingClientMessage(clientMessageID)
                let thumbnailIdentifier = try AuthenticatedThumbnailIdentifier(
                    authority: .outgoingClientMessage(clientMessageID),
                    envelopeSignature: envelopeSignature
                )

                // Persist under the locally generated, signed client ID before
                // starting an upload whose outcome may become ambiguous. No
                // relay response or post-upload filesystem commit is required
                // to recover this sender copy on a later refresh.
                let localPackageURL = try await mediaPipeline.persistOutgoingPackage(
                    package.localEncryptedCopyURL,
                    clientMessageID: clientMessageID
                )
                durableLocalPackageURL = localPackageURL

                // Durable persistence suspends. Recheck both exact identities
                // once more immediately before the relay receives ciphertext.
                guard self.currentUser?.id == currentUser.id,
                      deviceIdentity?.deviceID == senderDeviceID else {
                    throw ContactMessagingSecurityError.localIdentityMismatch
                }
                let uploadVerification = try verifiedRecipient(for: contact.contactID)
                guard uploadVerification.recipient.constantTimeEquals(initialVerification.recipient),
                      uploadVerification.context.localIdentity.constantTimeEquals(
                          initialVerification.context.localIdentity
                      ) else {
                    throw ContactMessagingSecurityError.identityChangedDuringSend
                }

                uploadStarted = true
                var message = try await apiClient.uploadMessage(
                    recipientID: initialVerification.recipient.userID,
                    recipientDeviceID: initialVerification.recipient.deviceID,
                    envelope: package.envelope,
                    encryptedBlobFileURL: package.encryptedBlobURL,
                    blobSize: package.blobSize
                )
                try validateUploadResponse(
                    message,
                    package: package,
                    senderUserID: currentUser.id,
                    senderDeviceID: senderDeviceID,
                    recipient: initialVerification.recipient,
                    localIdentity: initialVerification.context.localIdentity
                )

                // The upload suspension can overlap reset, deletion, refresh,
                // or re-verification. Do not derive or publish any local UI
                // state unless both exact identities are still current.
                guard self.currentUser?.id == currentUser.id,
                      deviceIdentity?.deviceID == senderDeviceID else {
                    throw ContactMessagingSecurityError.localIdentityMismatch
                }
                let responseVerification = try verifiedRecipient(for: contact.contactID)
                guard responseVerification.recipient.constantTimeEquals(initialVerification.recipient),
                      responseVerification.context.localIdentity.constantTimeEquals(
                          initialVerification.context.localIdentity
                      ) else {
                    throw ContactMessagingSecurityError.identityChangedDuringSend
                }

                message.createdAt = package.envelope.createdAt
                message.localEncryptedPackageURL = localPackageURL
                generatedThumbnailURL = try? await mediaPipeline.makeThumbnail(
                    videoURL: compressedVideoURL,
                    identifier: thumbnailIdentifier
                )

                // Thumbnail generation suspends and may recreate its temporary
                // root after a concurrent account reset. Recheck before exposing
                // the thumbnail, media URL, or sent message in app state.
                guard self.currentUser?.id == currentUser.id,
                      deviceIdentity?.deviceID == senderDeviceID else {
                    throw ContactMessagingSecurityError.localIdentityMismatch
                }
                let publicationVerification = try verifiedRecipient(for: contact.contactID)
                guard publicationVerification.recipient.constantTimeEquals(
                    initialVerification.recipient
                ), publicationVerification.context.localIdentity.constantTimeEquals(
                    initialVerification.context.localIdentity
                ) else {
                    throw ContactMessagingSecurityError.identityChangedDuringSend
                }
                message.localThumbnailURL = generatedThumbnailURL
                rememberLocalMedia(
                    for: message,
                    encryptedIdentifier: encryptedIdentifier,
                    thumbnailIdentifier: thumbnailIdentifier
                )

                messagesByContactID[initialVerification.recipient.userID, default: []].append(message)
                rebuildConversations()
                generatedThumbnailURL = nil
                let cleanupURLs = [compressedVideoURL, package.encryptedBlobURL, package.localEncryptedCopyURL]
                    .filter { $0 != message.localEncryptedPackageURL }
                await mediaPipeline.cleanupTemporaryFiles(cleanupURLs)
            } catch {
                var cleanupURLs = [compressedVideoURL]
                if let generatedPackage {
                    cleanupURLs.append(generatedPackage.encryptedBlobURL)
                    cleanupURLs.append(generatedPackage.localEncryptedCopyURL)
                }
                if !uploadStarted, let durableLocalPackageURL {
                    cleanupURLs.append(durableLocalPackageURL)
                }
                if let generatedThumbnailURL {
                    cleanupURLs.append(generatedThumbnailURL)
                }
                // Once upload starts, its result may be ambiguous. Keep the
                // durable client-ID copy so a later relay refresh can bind an
                // accepted signed envelope without duplicating the send.
                await mediaPipeline.cleanupTemporaryFiles(cleanupURLs)
                throw error
            }
        }
    }

    func preparePlayback(message: Message) async -> PlaybackTempFile? {
        var preparedPlaybackFile: PlaybackTempFile?

        await perform {
            var playableMessage = message
            let contactID = contactID(for: message)
            var shouldAcknowledgeDelivery = false
            var stagedReceivedPackage: StagedReceivedMediaPackage?
            var generatedPlaybackFile: PlaybackTempFile?
            var generatedThumbnailURL: URL?
            let authenticatedDirection = try authenticateMessageDirection(message)
            let incomingSecurity: IncomingMessageSecurityContext?
            switch authenticatedDirection {
            case .incoming(let security):
                incomingSecurity = security
            case .outgoing:
                incomingSecurity = nil
            }
            let mediaIdentifiers = try localMediaIdentifiers(
                for: message,
                direction: authenticatedDirection
            )
            let incomingOperationKey: IncomingReceiptOperationKey?
            if incomingSecurity != nil {
                incomingOperationKey = try beginIncomingReceiptOperation(for: message)
            } else {
                incomingOperationKey = nil
            }
            defer {
                if let incomingOperationKey {
                    endIncomingReceiptOperation(incomingOperationKey)
                }
            }

            do {
                if playableMessage.localEncryptedPackageURL == nil {
                    if let localURL = await mediaPipeline.localEncryptedPackageURL(
                        for: mediaIdentifiers.encrypted
                    ) {
                        try reauthenticateMessageDirection(
                            playableMessage,
                            expected: authenticatedDirection
                        )
                        playableMessage.localEncryptedPackageURL = localURL
                        shouldAcknowledgeDelivery = incomingSecurity != nil && message.status == .sent
                    } else {
                        guard incomingSecurity != nil else {
                            throw MediaPipelineError.cryptoOperationFailed("Finding a local encrypted copy for sent-message playback")
                        }
                        let downloadedBlobURL = try await apiClient.downloadMessage(id: message.id)
                        do {
                            let stagedPackage = try await mediaPipeline.stageReceivedPackage(
                                message: message,
                                downloadedBlobURL: downloadedBlobURL
                            )
                            stagedReceivedPackage = stagedPackage
                        } catch {
                            await mediaPipeline.cleanupTemporaryFiles([downloadedBlobURL])
                            throw error
                        }
                        await mediaPipeline.cleanupTemporaryFiles([downloadedBlobURL])

                        let acceptanceSecurity = try authenticateIncomingMessage(message)
                        let reservation = try await reserveNetworkReceipt(
                            message: message,
                            security: acceptanceSecurity
                        )
                        guard let stagedPackage = stagedReceivedPackage else {
                            throw MediaPipelineError.stagedPackageMissing
                        }
                        let package = try await mediaPipeline.commitStagedReceivedPackage(
                            stagedPackage,
                            allowExistingExactRecovery: reservation == .recoveringPending
                        )
                        stagedReceivedPackage = nil
                        let commitSecurity = try authenticateIncomingMessage(message)
                        try await markNetworkReceiptCommitted(
                            message: message,
                            security: commitSecurity
                        )
                        _ = try authenticateIncomingMessage(message)
                        playableMessage.localEncryptedPackageURL = package.localEncryptedCopyURL
                        shouldAcknowledgeDelivery = true
                        rememberLocalMedia(
                            for: playableMessage,
                            encryptedIdentifier: mediaIdentifiers.encrypted,
                            thumbnailIdentifier: mediaIdentifiers.thumbnail
                        )
                        upsert(playableMessage, contactID: contactID)
                    }
                } else {
                    shouldAcknowledgeDelivery = incomingSecurity != nil && message.status == .sent
                }

                guard let localEncryptedPackageURL = playableMessage.localEncryptedPackageURL else {
                    throw MediaPipelineError.cryptoOperationFailed("Finding the encrypted local media package")
                }
                let package = try playbackPackage(
                    for: playableMessage,
                    localEncryptedPackageURL: localEncryptedPackageURL,
                    direction: authenticatedDirection
                )
                if incomingSecurity != nil {
                    // A pending receipt may only be promoted after proving that
                    // the exact signed ciphertext, not merely its filename, is local.
                    try await mediaPipeline.validateEncryptedPackage(package)
                    let currentSecurity = try authenticateIncomingMessage(playableMessage)
                    try await validateLocalReceipt(
                        message: playableMessage,
                        security: currentSecurity
                    )
                }
                try reauthenticateMessageDirection(
                    playableMessage,
                    expected: authenticatedDirection
                )
                let playbackFile = try await mediaPipeline.decryptForPlayback(package: package)
                generatedPlaybackFile = playbackFile
                try reauthenticateMessageDirection(
                    playableMessage,
                    expected: authenticatedDirection
                )

                if playableMessage.localThumbnailURL == nil {
                    generatedThumbnailURL = try? await mediaPipeline.makeThumbnail(
                        videoURL: playbackFile.url,
                        identifier: mediaIdentifiers.thumbnail
                    )
                    // Thumbnail generation suspends after plaintext exists. Do not
                    // publish that derivative if the current relay contact no longer
                    // matches the verified pin.
                    try reauthenticateMessageDirection(
                        playableMessage,
                        expected: authenticatedDirection
                    )
                }

                if shouldAcknowledgeDelivery {
                    try reauthenticateMessageDirection(
                        playableMessage,
                        expected: authenticatedDirection
                    )
                    try await apiClient.acknowledgeDelivered(messageID: playableMessage.id)
                    try reauthenticateMessageDirection(
                        playableMessage,
                        expected: authenticatedDirection
                    )
                    playableMessage.status = .delivered
                }

                try reauthenticateMessageDirection(
                    playableMessage,
                    expected: authenticatedDirection
                )
                let previousPlaybackURL = activePlaybackFile?.url
                if let previousPlaybackURL, previousPlaybackURL != playbackFile.url {
                    if activePlaybackFile?.url == previousPlaybackURL {
                        playbackCleanupTask?.cancel()
                        playbackCleanupTask = nil
                        activePlaybackFile = nil
                    }
                    await mediaPipeline.cleanupTemporaryFiles([previousPlaybackURL])
                }

                // This is the final pin check after every suspension above. No
                // plaintext playback file, thumbnail, or delivery state is exposed
                // until the current contact still exactly matches the verified pin.
                try reauthenticateMessageDirection(
                    playableMessage,
                    expected: authenticatedDirection
                )
                if let generatedThumbnailURL {
                    playableMessage.localThumbnailURL = generatedThumbnailURL
                }
                if generatedThumbnailURL != nil || shouldAcknowledgeDelivery {
                    rememberLocalMedia(
                        for: playableMessage,
                        encryptedIdentifier: mediaIdentifiers.encrypted,
                        thumbnailIdentifier: mediaIdentifiers.thumbnail
                    )
                    upsert(playableMessage, contactID: contactID)
                }
                activePlaybackFile = playbackFile
                schedulePlaybackCleanup(for: playbackFile)
                preparedPlaybackFile = playbackFile
                generatedPlaybackFile = nil
                generatedThumbnailURL = nil
            } catch {
                if let stagedReceivedPackage {
                    await mediaPipeline.discardStagedReceivedPackage(stagedReceivedPackage)
                }
                if let generatedPlaybackFile {
                    await mediaPipeline.cleanupTemporaryFiles([generatedPlaybackFile.url])
                }
                if let generatedThumbnailURL {
                    await mediaPipeline.cleanupTemporaryFiles([generatedThumbnailURL])
                }
                throw error
            }
        }

        return preparedPlaybackFile
    }

    private func refreshLocalState() async throws {
        guard let expectedUserID = currentUser?.id,
              let expectedDeviceID = deviceIdentity?.deviceID else {
            throw DeviceKeyManagerError.identityNotFound
        }
        let expectedAuthority = RefreshAuthority(
            generation: accountStateGeneration,
            userID: expectedUserID,
            deviceID: expectedDeviceID
        )
        let refreshedContacts = try await apiClient.listContacts()
        try requireRefreshAuthority(expectedAuthority)
        let fetchedMessages = try await apiClient.listMessages()
        try requireRefreshAuthority(expectedAuthority)
        let trustAssessments = try observeTrust(for: refreshedContacts)

        // Message hydration needs the refreshed contacts in order to authenticate
        // relay records. Check the exact account authority immediately before this
        // temporary publication so a response from a revoked session cannot put
        // its contacts back after reset.
        try requireRefreshAuthority(expectedAuthority)
        contacts = refreshedContacts
        contactTrustAssessments = trustAssessments
        let messages = await hydrateLocalMedia(
            on: fetchedMessages,
            requiring: expectedAuthority
        )
        try requireRefreshAuthority(expectedAuthority)
        messagesByContactID = group(messages: messages, contacts: refreshedContacts)
        rebuildConversations()
        await generateMissingThumbnails(for: messages)
        try requireRefreshAuthority(expectedAuthority)
        await cachePendingIncomingMessages(messages)
        try requireRefreshAuthority(expectedAuthority)
    }

    private func observeTrust(for refreshedContacts: [Contact]) throws -> [UUID: ContactTrustAssessment] {
        guard let currentUser, let deviceIdentity else {
            throw DeviceKeyManagerError.identityNotFound
        }
        guard let relayURL = URL(string: relayBaseURLString) else {
            throw ContactVerificationError.invalidRelayURL
        }

        var assessments: [UUID: ContactTrustAssessment] = [:]
        for contact in refreshedContacts {
            let context = try ContactVerificationContext(
                relayURL: relayURL,
                localUser: currentUser,
                localDeviceIdentity: deviceIdentity,
                contact: contact
            )
            assessments[contact.contactID] = try contactTrustStore.observe(context)
        }
        return assessments
    }

    private func makeVerificationContext(for contact: Contact) throws -> ContactVerificationContext {
        guard let currentUser, let deviceIdentity else {
            throw DeviceKeyManagerError.identityNotFound
        }
        guard let relayURL = URL(string: relayBaseURLString) else {
            throw ContactVerificationError.invalidRelayURL
        }
        guard let currentContact = contacts.first(where: { $0.contactID == contact.contactID }) else {
            throw ContactMessagingSecurityError.verifiedContactMissing
        }
        return try ContactVerificationContext(
            relayURL: relayURL,
            localUser: currentUser,
            localDeviceIdentity: deviceIdentity,
            contact: currentContact
        )
    }

    private func makeTrustRemovalScope(for contact: Contact) throws -> ContactTrustRemovalScope {
        guard let currentUser, let localDeviceID = deviceIdentity?.deviceID else {
            throw DeviceKeyManagerError.identityNotFound
        }
        guard let relayURL = URL(string: relayBaseURLString) else {
            throw ContactVerificationError.invalidRelayURL
        }
        return try ContactTrustRemovalScope(
            relayURL: relayURL,
            localUserID: currentUser.id,
            localDeviceID: localDeviceID,
            remoteUserID: contact.contactID,
            remoteDeviceID: contact.deviceID
        )
    }

    private func verifiedRecipient(
        for contactID: UUID
    ) throws -> (context: ContactVerificationContext, recipient: ContactVerificationIdentity) {
        guard let currentContact = contacts.first(where: { $0.contactID == contactID }) else {
            throw ContactMessagingSecurityError.verifiedContactMissing
        }
        let context = try makeVerificationContext(for: currentContact)
        let assessment = try contactTrustStore.observe(context)
        contactTrustAssessments[currentContact.contactID] = assessment
        guard assessment.state == .verified,
              let recipient = assessment.trustedIdentity,
              recipient.constantTimeEquals(context.remoteIdentity) else {
            throw ContactMessagingSecurityError.verificationRequired(assessment.state)
        }
        return (context, recipient)
    }

    private func validateUploadResponse(
        _ message: Message,
        package: EncryptedMediaPackage,
        senderUserID: UUID,
        senderDeviceID: UUID,
        recipient: ContactVerificationIdentity,
        localIdentity: ContactVerificationIdentity
    ) throws {
        guard message.envelope == package.envelope,
              message.blobSize == package.blobSize,
              message.status == .sent,
              message.encryptedBlobPath?.isEmpty == false else {
            throw ContactMessagingSecurityError.invalidUploadResponse
        }

        try messageAuthenticator.verify(
            message: message,
            expectedSenderUserID: senderUserID,
            expectedSenderDeviceID: senderDeviceID,
            expectedSenderIdentityDigest: try localIdentity.identityDigest,
            expectedSenderSigningPublicKey: localIdentity.signingPublicKey,
            expectedRecipientUserID: recipient.userID,
            expectedRecipientDeviceID: recipient.deviceID,
            expectedRecipientIdentityDigest: try recipient.identityDigest
        )
    }

    func hydrateLocalMedia(on messages: [Message]) async -> [Message] {
        await hydrateLocalMedia(on: messages, requiring: currentRefreshAuthority)
    }

    private func hydrateLocalMedia(
        on messages: [Message],
        requiring expectedAuthority: RefreshAuthority?
    ) async -> [Message] {
        var hydratedMessages = messages.map { message in
            var sanitizedMessage = message
            sanitizedMessage.localEncryptedPackageURL = nil
            sanitizedMessage.localThumbnailURL = nil
            return sanitizedMessage
        }
        for index in hydratedMessages.indices {
            guard expectedAuthority.map(refreshAuthorityIsCurrent) ?? true else {
                return hydratedMessages
            }
            let message = hydratedMessages[index]

            do {
                // Never let unauthenticated relay metadata select local media or
                // plaintext UI state, even when it copies an existing signature.
                let direction = try authenticateMessageDirection(message)
                let identifiers = try localMediaIdentifiers(
                    for: message,
                    direction: direction
                )

                if let rememberedURL = localEncryptedPackageURLs[identifiers.encrypted] {
                    hydratedMessages[index].localEncryptedPackageURL = rememberedURL
                } else if let cachedURL = await mediaPipeline.localEncryptedPackageURL(
                    for: identifiers.encrypted
                ) {
                    guard expectedAuthority.map(refreshAuthorityIsCurrent) ?? true else {
                        return hydratedMessages
                    }
                    try reauthenticateMessageDirection(message, expected: direction)
                    hydratedMessages[index].localEncryptedPackageURL = cachedURL
                    localEncryptedPackageURLs[identifiers.encrypted] = cachedURL
                }

                if let rememberedURL = localThumbnailURLs[identifiers.thumbnail] {
                    hydratedMessages[index].localThumbnailURL = rememberedURL
                } else if let cachedURL = await mediaPipeline.localThumbnailURL(
                    for: identifiers.thumbnail
                ) {
                    guard expectedAuthority.map(refreshAuthorityIsCurrent) ?? true else {
                        return hydratedMessages
                    }
                    try reauthenticateMessageDirection(message, expected: direction)
                    hydratedMessages[index].localThumbnailURL = cachedURL
                    localThumbnailURLs[identifiers.thumbnail] = cachedURL
                }
            } catch {
                // Fetched relay metadata must authenticate before it can bind
                // any local ciphertext or thumbnail path.
                hydratedMessages[index].localEncryptedPackageURL = nil
                hydratedMessages[index].localThumbnailURL = nil
            }
        }
        return hydratedMessages
    }

    private var currentRefreshAuthority: RefreshAuthority? {
        guard !isClearingLocalAccountState,
              let userID = currentUser?.id,
              let deviceID = deviceIdentity?.deviceID else {
            return nil
        }
        return RefreshAuthority(
            generation: accountStateGeneration,
            userID: userID,
            deviceID: deviceID
        )
    }

    private func refreshAuthorityIsCurrent(_ expected: RefreshAuthority) -> Bool {
        currentRefreshAuthority == expected
    }

    private func requireRefreshAuthority(_ expected: RefreshAuthority) throws {
        guard refreshAuthorityIsCurrent(expected) else {
            // Reset revokes the device identity before its asynchronous cleanup.
            // Clear only when authority is absent; if another session is already
            // active, its published state belongs to that session and must not be
            // clobbered by this stale refresh finishing late.
            if currentUser == nil || deviceIdentity?.deviceID == nil {
                contacts = []
                contactTrustAssessments = [:]
                conversations = []
                messagesByContactID = [:]
                localEncryptedPackageURLs = [:]
                localThumbnailURLs = [:]
            }
            throw ContactMessagingSecurityError.localIdentityMismatch
        }
    }

    private func cachePendingIncomingMessages(_ messages: [Message]) async {
        guard let currentUserID = currentUser?.id,
              let localDeviceID = deviceIdentity?.deviceID else {
            return
        }

        let pendingMessages = messages.filter { message in
            message.recipientID == currentUserID &&
            message.recipientDeviceID == localDeviceID &&
            message.status == .sent &&
            message.encryptedBlobPath != nil &&
            message.localEncryptedPackageURL == nil
        }

        for message in pendingMessages {
            guard !Task.isCancelled else {
                return
            }
            await cacheIncomingMessage(message)
        }
    }

    private func authenticateIncomingMessage(_ message: Message) throws -> IncomingMessageSecurityContext {
        guard let currentUser,
              let localDeviceID = deviceIdentity?.deviceID,
              let contact = contacts.first(where: { $0.contactID == message.senderID }) else {
            throw ContactMessagingSecurityError.verifiedContactMissing
        }

        let verificationContext = try makeVerificationContext(for: contact)
        let trustAssessment = try contactTrustStore.observe(verificationContext)
        contactTrustAssessments[contact.contactID] = trustAssessment
        guard trustAssessment.state == .verified,
              let verifiedSender = trustAssessment.trustedIdentity,
              verifiedSender.constantTimeEquals(verificationContext.remoteIdentity) else {
            throw ContactMessagingSecurityError.verificationRequired(trustAssessment.state)
        }

        try messageAuthenticator.verify(
            message: message,
            expectedSenderUserID: verifiedSender.userID,
            expectedSenderDeviceID: verifiedSender.deviceID,
            expectedSenderIdentityDigest: try verifiedSender.identityDigest,
            expectedSenderSigningPublicKey: verifiedSender.signingPublicKey,
            expectedRecipientUserID: currentUser.id,
            expectedRecipientDeviceID: localDeviceID,
            expectedRecipientIdentityDigest: try verificationContext.localIdentity.identityDigest
        )

        return IncomingMessageSecurityContext(
            verificationContext: verificationContext,
            verifiedSender: verifiedSender
        )
    }

    private func authenticateMessageDirection(_ message: Message) throws -> AuthenticatedMessageDirection {
        guard let currentUser, let localDeviceID = deviceIdentity?.deviceID else {
            throw DeviceKeyManagerError.identityNotFound
        }

        let relationship = try MessageRelationshipResolver.resolve(
            message: message,
            localUserID: currentUser.id,
            localDeviceID: localDeviceID
        )

        if relationship == .incoming {
            return .incoming(try authenticateIncomingMessage(message))
        }

        guard let contact = contacts.first(where: { $0.contactID == message.recipientID }) else {
            throw ContactMessagingSecurityError.verifiedContactMissing
        }
        let verificationContext = try makeVerificationContext(for: contact)
        let trustAssessment = try contactTrustStore.observe(verificationContext)
        contactTrustAssessments[contact.contactID] = trustAssessment
        guard trustAssessment.state == .verified,
              let verifiedRecipient = trustAssessment.trustedIdentity,
              verifiedRecipient.constantTimeEquals(verificationContext.remoteIdentity) else {
            throw ContactMessagingSecurityError.verificationRequired(trustAssessment.state)
        }

        try messageAuthenticator.verify(
            message: message,
            expectedSenderUserID: currentUser.id,
            expectedSenderDeviceID: localDeviceID,
            expectedSenderIdentityDigest: try verificationContext.localIdentity.identityDigest,
            expectedSenderSigningPublicKey: verificationContext.localIdentity.signingPublicKey,
            expectedRecipientUserID: verifiedRecipient.userID,
            expectedRecipientDeviceID: verifiedRecipient.deviceID,
            expectedRecipientIdentityDigest: try verifiedRecipient.identityDigest
        )
        return .outgoing
    }

    private func reauthenticateMessageDirection(
        _ message: Message,
        expected: AuthenticatedMessageDirection
    ) throws {
        let current = try authenticateMessageDirection(message)
        switch (expected, current) {
        case (.incoming, .incoming), (.outgoing, .outgoing):
            return
        default:
            throw MessageEnvelopeAuthenticationError.unexpectedRelationship
        }
    }

    private func reserveNetworkReceipt(
        message: Message,
        security: IncomingMessageSecurityContext
    ) async throws -> MessageReplayReservation {
        guard let clientMessageID = message.envelope.clientMessageID,
              let signature = message.envelope.signature else {
            throw MessageEnvelopeAuthenticationError.missingField("replay receipt binding")
        }
        return try await messageReplayStore.reserveNetworkReceipt(
            clientMessageID: clientMessageID,
            serverMessageID: message.id,
            senderIdentityDigest: try security.verifiedSender.identityDigest,
            relayScopeHash: security.verificationContext.localIdentity.relayScopeHash,
            localDeviceID: security.verificationContext.localIdentity.deviceID,
            authenticatedEnvelopeSignature: signature
        )
    }

    private func beginIncomingReceiptOperation(
        for message: Message
    ) throws -> IncomingReceiptOperationKey {
        guard let clientMessageID = message.envelope.clientMessageID else {
            throw MessageEnvelopeAuthenticationError.missingField("client message ID")
        }
        let key = IncomingReceiptOperationKey(
            senderUserID: message.senderID,
            clientMessageID: clientMessageID
        )
        guard activeIncomingReceiptOperations.insert(key).inserted else {
            throw ContactMessagingSecurityError.incomingOperationInProgress
        }
        return key
    }

    private func endIncomingReceiptOperation(_ key: IncomingReceiptOperationKey) {
        activeIncomingReceiptOperations.remove(key)
    }

    private func markNetworkReceiptCommitted(
        message: Message,
        security: IncomingMessageSecurityContext
    ) async throws {
        guard let clientMessageID = message.envelope.clientMessageID,
              let signature = message.envelope.signature else {
            throw MessageEnvelopeAuthenticationError.missingField("replay receipt binding")
        }
        try await messageReplayStore.markPendingReceiptCommitted(
            clientMessageID: clientMessageID,
            serverMessageID: message.id,
            senderIdentityDigest: try security.verifiedSender.identityDigest,
            relayScopeHash: security.verificationContext.localIdentity.relayScopeHash,
            localDeviceID: security.verificationContext.localIdentity.deviceID,
            authenticatedEnvelopeSignature: signature
        )
    }

    private func validateLocalReceipt(
        message: Message,
        security: IncomingMessageSecurityContext
    ) async throws {
        guard let clientMessageID = message.envelope.clientMessageID,
              let signature = message.envelope.signature else {
            throw MessageEnvelopeAuthenticationError.missingField("replay receipt binding")
        }
        try await messageReplayStore.validateLocalMessage(
            clientMessageID: clientMessageID,
            serverMessageID: message.id,
            senderIdentityDigest: try security.verifiedSender.identityDigest,
            relayScopeHash: security.verificationContext.localIdentity.relayScopeHash,
            localDeviceID: security.verificationContext.localIdentity.deviceID,
            authenticatedEnvelopeSignature: signature
        )
    }

    private func cacheIncomingMessage(_ message: Message) async {
        var stagedReceivedPackage: StagedReceivedMediaPackage?
        var generatedThumbnailURL: URL?
        var incomingOperationKey: IncomingReceiptOperationKey?
        defer {
            if let incomingOperationKey {
                endIncomingReceiptOperation(incomingOperationKey)
            }
        }
        do {
            _ = try authenticateIncomingMessage(message)
            incomingOperationKey = try beginIncomingReceiptOperation(for: message)
            let contactID = contactID(for: message)
            let downloadedBlobURL = try await apiClient.downloadMessage(id: message.id)
            do {
                let stagedPackage = try await mediaPipeline.stageReceivedPackage(
                    message: message,
                    downloadedBlobURL: downloadedBlobURL
                )
                stagedReceivedPackage = stagedPackage
            } catch {
                await mediaPipeline.cleanupTemporaryFiles([downloadedBlobURL])
                throw error
            }
            await mediaPipeline.cleanupTemporaryFiles([downloadedBlobURL])

            var cachedMessage = message
            let acceptanceSecurity = try authenticateIncomingMessage(cachedMessage)
            let reservation = try await reserveNetworkReceipt(
                message: cachedMessage,
                security: acceptanceSecurity
            )
            guard let stagedPackage = stagedReceivedPackage else {
                throw MediaPipelineError.stagedPackageMissing
            }
            let package = try await mediaPipeline.commitStagedReceivedPackage(
                stagedPackage,
                allowExistingExactRecovery: reservation == .recoveringPending
            )
            stagedReceivedPackage = nil
            let commitSecurity = try authenticateIncomingMessage(cachedMessage)
            try await markNetworkReceiptCommitted(
                message: cachedMessage,
                security: commitSecurity
            )
            let postCommitSecurity = try authenticateIncomingMessage(cachedMessage)
            let mediaIdentifiers = try localMediaIdentifiers(
                for: cachedMessage,
                direction: .incoming(postCommitSecurity)
            )
            cachedMessage.localEncryptedPackageURL = package.localEncryptedCopyURL
            rememberLocalMedia(
                for: cachedMessage,
                encryptedIdentifier: mediaIdentifiers.encrypted,
                thumbnailIdentifier: mediaIdentifiers.thumbnail
            )
            upsert(cachedMessage, contactID: contactID)

            let playbackSecurity = try authenticateIncomingMessage(cachedMessage)
            try await validateLocalReceipt(message: cachedMessage, security: playbackSecurity)
            _ = try authenticateIncomingMessage(cachedMessage)
            if let thumbnailURL = try await makeThumbnail(
                for: cachedMessage,
                localEncryptedPackageURL: package.localEncryptedCopyURL,
                direction: .incoming(playbackSecurity)
            ) {
                generatedThumbnailURL = thumbnailURL
                _ = try authenticateIncomingMessage(cachedMessage)
                cachedMessage.localThumbnailURL = thumbnailURL
                rememberLocalMedia(
                    for: cachedMessage,
                    encryptedIdentifier: mediaIdentifiers.encrypted,
                    thumbnailIdentifier: mediaIdentifiers.thumbnail
                )
                generatedThumbnailURL = nil
            }

            upsert(cachedMessage, contactID: contactID)
            _ = try authenticateIncomingMessage(cachedMessage)
            try await apiClient.acknowledgeDelivered(messageID: message.id)
            _ = try authenticateIncomingMessage(cachedMessage)
            cachedMessage.status = .delivered
            upsert(cachedMessage, contactID: contactID)
        } catch {
            if let stagedReceivedPackage {
                await mediaPipeline.discardStagedReceivedPackage(stagedReceivedPackage)
            }
            if let generatedThumbnailURL {
                await mediaPipeline.cleanupTemporaryFiles([generatedThumbnailURL])
            }
            // Keep the relay copy visible as a playable pending tile; the next refresh can retry.
        }
    }

    private func generateMissingThumbnails(for messages: [Message]) async {
        for message in messages.prefix(12) {
            guard message.localThumbnailURL == nil,
                  let localEncryptedPackageURL = message.localEncryptedPackageURL else {
                continue
            }

            var generatedThumbnailURL: URL?
            do {
                let direction = try authenticateMessageDirection(message)
                let incomingSecurity: IncomingMessageSecurityContext?
                if case .incoming(let security) = direction {
                    incomingSecurity = security
                } else {
                    incomingSecurity = nil
                }
                let incomingOperationKey: IncomingReceiptOperationKey?
                if incomingSecurity != nil {
                    incomingOperationKey = try beginIncomingReceiptOperation(for: message)
                } else {
                    incomingOperationKey = nil
                }
                defer {
                    if let incomingOperationKey {
                        endIncomingReceiptOperation(incomingOperationKey)
                    }
                }
                if incomingSecurity != nil {
                    let package = try playbackPackage(
                        for: message,
                        localEncryptedPackageURL: localEncryptedPackageURL,
                        direction: direction
                    )
                    try await mediaPipeline.validateEncryptedPackage(package)
                    let currentSecurity = try authenticateIncomingMessage(message)
                    try await validateLocalReceipt(
                        message: message,
                        security: currentSecurity
                    )
                }
                try reauthenticateMessageDirection(message, expected: direction)
                guard let thumbnailURL = try await makeThumbnail(
                    for: message,
                    localEncryptedPackageURL: localEncryptedPackageURL,
                    direction: direction
                ) else {
                    continue
                }
                generatedThumbnailURL = thumbnailURL
                try reauthenticateMessageDirection(message, expected: direction)

                var updatedMessage = message
                updatedMessage.localThumbnailURL = thumbnailURL
                let mediaIdentifiers = try localMediaIdentifiers(
                    for: updatedMessage,
                    direction: direction
                )
                rememberLocalMedia(
                    for: updatedMessage,
                    encryptedIdentifier: mediaIdentifiers.encrypted,
                    thumbnailIdentifier: mediaIdentifiers.thumbnail
                )
                upsert(updatedMessage, contactID: contactID(for: message))
                generatedThumbnailURL = nil
            } catch {
                if let generatedThumbnailURL {
                    await mediaPipeline.cleanupTemporaryFiles([generatedThumbnailURL])
                }
                print("Kithra thumbnail generation failed for \(message.id.uuidString): \(error.localizedDescription)")
            }
        }
    }

    private func makeThumbnail(
        for message: Message,
        localEncryptedPackageURL: URL,
        direction: AuthenticatedMessageDirection
    ) async throws -> URL? {
        let mediaIdentifiers = try localMediaIdentifiers(
            for: message,
            direction: direction
        )
        let package = try playbackPackage(
            for: message,
            localEncryptedPackageURL: localEncryptedPackageURL,
            direction: direction
        )
        try reauthenticateMessageDirection(message, expected: direction)
        let playbackFile = try await mediaPipeline.decryptForPlayback(package: package)
        var generatedThumbnailURL: URL?
        do {
            try reauthenticateMessageDirection(message, expected: direction)
            let thumbnailURL = try await mediaPipeline.makeThumbnail(
                videoURL: playbackFile.url,
                identifier: mediaIdentifiers.thumbnail
            )
            generatedThumbnailURL = thumbnailURL
            try reauthenticateMessageDirection(message, expected: direction)
            await mediaPipeline.cleanupTemporaryFiles([playbackFile.url])
            try reauthenticateMessageDirection(message, expected: direction)
            generatedThumbnailURL = nil
            return thumbnailURL
        } catch {
            var cleanupURLs = [playbackFile.url]
            if let generatedThumbnailURL {
                cleanupURLs.append(generatedThumbnailURL)
            }
            await mediaPipeline.cleanupTemporaryFiles(cleanupURLs)
            throw error
        }
    }

    private func rebuildConversations() {
        conversations = contacts.map { contact in
            let contactMessages = messagesByContactID[contact.contactID, default: []]
                .sorted { $0.createdAt < $1.createdAt }
            let latest = contactMessages.last
            let unreadCount = contactMessages.filter { message in
                message.senderID == contact.contactID && message.status == .sent
            }.count

            return ConversationSummary(
                contact: contact,
                latestMessage: latest,
                unreadCount: unreadCount
            )
        }
        .sorted {
            ($0.latestMessage?.createdAt ?? .distantPast) > ($1.latestMessage?.createdAt ?? .distantPast)
        }
    }

    private func schedulePlaybackCleanup(for playbackFile: PlaybackTempFile) {
        playbackCleanupTask?.cancel()
        let delay = max(0, playbackFile.cleanupDeadline.timeIntervalSinceNow)
        playbackCleanupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  self?.activePlaybackFile?.id == playbackFile.id else {
                return
            }
            await self?.discardActivePlaybackFile()
        }
    }

    private func group(messages: [Message], contacts: [Contact]) -> [UUID: [Message]] {
        let contactIDs = Set(contacts.map(\.contactID))
        var grouped: [UUID: [Message]] = [:]

        for message in messages {
            let otherID = contactIDs.contains(message.senderID) ? message.senderID : message.recipientID
            grouped[otherID, default: []].append(message)
        }

        return grouped
    }

    private func playbackPackage(
        for message: Message,
        localEncryptedPackageURL: URL,
        direction: AuthenticatedMessageDirection
    ) throws -> EncryptedMediaPackage {
        var playbackEnvelope = message.envelope
        if case .outgoing = direction {
            guard let senderContentKey = message.envelope.senderContentKey else {
                throw MediaPipelineError.cryptoOperationFailed("Finding the sender content-key envelope")
            }
            playbackEnvelope.contentKey = senderContentKey
        }

        return EncryptedMediaPackage(
            id: message.id,
            messageID: message.id,
            envelope: playbackEnvelope,
            encryptedBlobURL: localEncryptedPackageURL,
            localEncryptedCopyURL: localEncryptedPackageURL,
            blobSize: message.blobSize
        )
    }

    private func localMediaIdentifiers(
        for message: Message,
        direction: AuthenticatedMessageDirection
    ) throws -> (
        encrypted: LocalEncryptedMediaIdentifier,
        thumbnail: AuthenticatedThumbnailIdentifier
    ) {
        guard let envelopeSignature = message.envelope.signature else {
            throw MessageEnvelopeAuthenticationError.missingField("signature")
        }

        switch direction {
        case .outgoing:
            guard let clientMessageID = message.envelope.clientMessageID else {
                throw MessageEnvelopeAuthenticationError.missingField("client message ID")
            }
            return (
                .outgoingClientMessage(clientMessageID),
                try AuthenticatedThumbnailIdentifier(
                    authority: .outgoingClientMessage(clientMessageID),
                    envelopeSignature: envelopeSignature
                )
            )
        case .incoming:
            return (
                .incomingServerMessage(message.id),
                try AuthenticatedThumbnailIdentifier(
                    authority: .incomingServerMessage(message.id),
                    envelopeSignature: envelopeSignature
                )
            )
        }
    }

    private func rememberLocalMedia(
        for message: Message,
        encryptedIdentifier: LocalEncryptedMediaIdentifier,
        thumbnailIdentifier: AuthenticatedThumbnailIdentifier
    ) {
        if let localEncryptedPackageURL = message.localEncryptedPackageURL {
            localEncryptedPackageURLs[encryptedIdentifier] = localEncryptedPackageURL
        }
        if let localThumbnailURL = message.localThumbnailURL {
            localThumbnailURLs[thumbnailIdentifier] = localThumbnailURL
        }
    }

    private func contactID(for message: Message) -> UUID {
        if let currentUserID = currentUser?.id {
            return message.senderID == currentUserID ? message.recipientID : message.senderID
        }
        return message.senderID
    }

    private func upsert(_ contact: Contact) {
        if let index = contacts.firstIndex(where: { $0.contactID == contact.contactID }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
    }

    private func removeContactLocally(contactID: UUID) {
        contacts.removeAll { $0.contactID == contactID }
        contactTrustAssessments[contactID] = nil
        messagesByContactID[contactID] = nil
        rebuildConversations()
    }

    private func upsert(_ message: Message, contactID: UUID) {
        var messages = messagesByContactID[contactID, default: []]
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messagesByContactID[contactID] = messages
        rebuildConversations()
    }

    @discardableResult
    private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !isClearingLocalAccountState else {
            return false
        }
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }

        do {
            try await operation()
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    private func clearLocalAccountState() async {
        isClearingLocalAccountState = true
        defer { isClearingLocalAccountState = false }
        accountStateGeneration &+= 1
        stopRemotePolling()
        playbackCleanupTask?.cancel()
        playbackCleanupTask = nil
        let activePlaybackURL = activePlaybackFile?.url

        // Revoke all in-memory authority before the first cleanup suspension.
        // Otherwise a concurrent verification task can recreate a Keychain pin
        // after removeAll() and leave it behind when reset completes.
        UserDefaults.standard.removeObject(forKey: Self.persistedSessionKey)
        deviceIdentity = nil
        contacts = []
        contactTrustAssessments = [:]
        conversations = []
        messagesByContactID = [:]
        localEncryptedPackageURLs = [:]
        localThumbnailURLs = [:]
        lastInviteCode = nil
        activePlaybackFile = nil
        activeIncomingReceiptOperations = []

        await apiClient.setBearerToken(nil)
        if let activePlaybackURL {
            await mediaPipeline.cleanupTemporaryFiles([activePlaybackURL])
        }
        await mediaPipeline.removeAllLocalMedia()
        try? contactTrustStore.removeAll()
        try? await messageReplayStore.removeAll()
        try? await keyManager.removeIdentity()
        // Keep RootView on the signed-in surface until all cleanup awaits finish;
        // otherwise SetupView can auto-create a replacement key while reset is
        // still deleting Keychain state.
        currentUser = nil
    }

    private func clearResidualKeychainAfterFreshInstallIfNeeded() async throws {
        guard requiresFreshInstallKeychainReset else {
            return
        }

        // UserDefaults is removed by uninstall while Keychain items may remain.
        // Remove every app-owned identity/trust/replay namespace before creating
        // a fresh identity so an old verification pin cannot silently reappear.
        try contactTrustStore.removeAll()
        try await messageReplayStore.removeAll()
        try await keyManager.removeIdentity()
        UserDefaults.standard.set(true, forKey: Self.installMarkerKey)
        requiresFreshInstallKeychainReset = false
    }

    private func restore(_ persistedSession: PersistedAuthSession) async {
        guard let relayURL = URL(string: persistedSession.relayBaseURLString) else {
            return
        }
        let restoreGeneration = accountStateGeneration

        let identityRestored = await perform {
            guard let identity = try await keyManager.currentIdentity() else {
                throw DeviceKeyManagerError.identityNotFound
            }
            guard accountStateGeneration == restoreGeneration,
                  !isClearingLocalAccountState else {
                throw ContactMessagingSecurityError.localIdentityMismatch
            }
            try validateLocalIdentity(identity, against: persistedSession.session)
            currentUser = persistedSession.session.user
            deviceIdentity = identity
        }
        guard accountStateGeneration == restoreGeneration,
              !isClearingLocalAccountState else {
            return
        }
        guard identityRestored else {
            await apiClient.setBearerToken(nil)
            UserDefaults.standard.removeObject(forKey: Self.persistedSessionKey)
            currentUser = nil
            deviceIdentity = nil
            contacts = []
            contactTrustAssessments = [:]
            conversations = []
            messagesByContactID = [:]
            return
        }

        await apiClient.updateBaseURL(relayURL)
        guard accountStateGeneration == restoreGeneration,
              !isClearingLocalAccountState else {
            return
        }
        await apiClient.setBearerToken(persistedSession.session.bearerToken)
        guard accountStateGeneration == restoreGeneration,
              !isClearingLocalAccountState else {
            await apiClient.setBearerToken(nil)
            return
        }
        await perform {
            try await refreshLocalState()
        }
    }

    private func validateRegistrationSession(
        _ session: AuthSession,
        requestedUsername: String,
        localIdentity: DevicePublicIdentity
    ) throws {
        guard session.user.username == requestedUsername,
              session.device.userID == session.user.id,
              localIdentity.deviceID == nil || localIdentity.deviceID == session.device.id,
              timingSafeEquals(localIdentity.encryptionPublicKey, session.device.encryptionPublicKey),
              timingSafeEquals(localIdentity.signingPublicKey, session.device.signingPublicKey) else {
            throw ContactMessagingSecurityError.localIdentityMismatch
        }
    }

    private func validateLocalIdentity(
        _ identity: DevicePublicIdentity,
        against session: AuthSession
    ) throws {
        guard session.device.userID == session.user.id,
              identity.deviceID == session.device.id,
              timingSafeEquals(identity.encryptionPublicKey, session.device.encryptionPublicKey),
              timingSafeEquals(identity.signingPublicKey, session.device.signingPublicKey) else {
            throw ContactMessagingSecurityError.localIdentityMismatch
        }
    }

    private func timingSafeEquals(_ first: Data, _ second: Data) -> Bool {
        guard first.count == second.count else {
            return false
        }
        var difference: UInt8 = 0
        for (left, right) in zip(first, second) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private func persist(session: AuthSession) {
        let persistedSession = PersistedAuthSession(
            relayBaseURLString: relayBaseURLString,
            session: session
        )
        guard let data = try? Self.sessionEncoder.encode(persistedSession) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.persistedSessionKey)
    }

    private func persistRelayBaseURLString() {
        guard var persistedSession = Self.loadPersistedSession() else {
            return
        }
        persistedSession.relayBaseURLString = relayBaseURLString
        guard let data = try? Self.sessionEncoder.encode(persistedSession) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.persistedSessionKey)
    }

    private static func loadPersistedSession() -> PersistedAuthSession? {
        guard let data = UserDefaults.standard.data(forKey: persistedSessionKey) else {
            return nil
        }
        return try? sessionDecoder.decode(PersistedAuthSession.self, from: data)
    }

    private static var bundledDefaultRelayURL: URL {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "KithraDefaultRelayURL") as? String else {
            return localDefaultRelayURL
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$("), let url = URL(string: trimmed) else {
            return localDefaultRelayURL
        }
        return url
    }

    private static let sessionEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let sessionDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct PersistedAuthSession: Codable, Hashable {
    var relayBaseURLString: String
    var session: AuthSession
}

private struct IncomingMessageSecurityContext {
    let verificationContext: ContactVerificationContext
    let verifiedSender: ContactVerificationIdentity
}

private enum AuthenticatedMessageDirection {
    case incoming(IncomingMessageSecurityContext)
    case outgoing
}

private struct IncomingReceiptOperationKey: Hashable {
    let senderUserID: UUID
    let clientMessageID: UUID
}

private struct RefreshAuthority: Equatable {
    let generation: UInt64
    let userID: UUID
    let deviceID: UUID
}

private enum ContactMessagingSecurityError: Error, LocalizedError {
    case verificationRequired(ContactTrustState)
    case verifiedContactMissing
    case localIdentityMismatch
    case localIdentityAlreadyBound
    case identityChangedDuringSend
    case identityChangedDuringVerification
    case invalidUploadResponse
    case incomingOperationInProgress

    var errorDescription: String? {
        switch self {
        case .verificationRequired(.unverified):
            return "Verify this contact's safety number before sending or playing videos."
        case .verificationRequired(.keyChanged):
            return "This contact's safety number changed. Sending and playback are paused until you verify it again."
        case .verificationRequired(.verified):
            return "The verified contact identity is unavailable. Verify the safety number again."
        case .verifiedContactMissing:
            return "The message sender is not a current verified contact."
        case .localIdentityMismatch:
            return "This device's protected keys do not match its relay session. Sign in again before trusting contacts or messages."
        case .localIdentityAlreadyBound:
            return "This protected identity is already bound to a relay account. Reset the local identity before registering a replacement account."
        case .identityChangedDuringSend:
            return "The contact or device identity changed while preparing this video. Verify the safety number again before sending."
        case .identityChangedDuringVerification:
            return "The contact or device identity changed while preparing verification. Refresh and compare the current safety number again."
        case .invalidUploadResponse:
            return "The relay returned message metadata that does not match the authenticated upload. The response was rejected."
        case .incomingOperationInProgress:
            return "This authenticated message is already being received. Try again after the current operation finishes."
        }
    }
}
