import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let persistedSessionKey = "speakeasy.authSession.v1"
    private static let localDefaultRelayURL = URL(string: "http://localhost:8080")!

    @Published var relayBaseURLString: String
    @Published var currentUser: SpeakeasyUser?
    @Published var deviceIdentity: DevicePublicIdentity?
    @Published var contacts: [Contact]
    @Published var conversations: [ConversationSummary]
    @Published var messagesByContactID: [UUID: [Message]]
    @Published var lastInviteCode: String?
    @Published var lastErrorMessage: String?
    @Published var activePlaybackFile: PlaybackTempFile?
    @Published var isWorking = false

    let apiClient: SpeakeasyAPIClient
    let keyManager: DeviceKeyManaging
    let mediaPipeline: MediaPipelining
    private var isRefreshingQuietly = false
    private var localEncryptedPackageURLs: [UUID: URL] = [:]
    private var localThumbnailURLs: [UUID: URL] = [:]
    private var remotePollingTask: Task<Void, Never>?

    init(
        relayBaseURL: URL? = nil,
        apiClient: SpeakeasyAPIClient? = nil,
        keyManager: DeviceKeyManaging = KeychainDeviceKeyManager(),
        mediaPipeline: MediaPipelining = DefaultMediaPipeline(),
        seedPreviewData: Bool = true
    ) {
        let effectiveRelayBaseURL = relayBaseURL ?? Self.bundledDefaultRelayURL
        self.relayBaseURLString = effectiveRelayBaseURL.absoluteString
        self.apiClient = apiClient ?? SpeakeasyAPIClient(configuration: APIConfiguration(baseURL: effectiveRelayBaseURL))
        self.keyManager = keyManager
        self.mediaPipeline = mediaPipeline
        let persistedSession = Self.loadPersistedSession()

        if seedPreviewData {
            let preview = PreviewData.sample
            self.currentUser = preview.currentUser
            self.deviceIdentity = preview.deviceIdentity
            self.contacts = preview.contacts
            self.conversations = preview.conversations
            self.messagesByContactID = preview.messagesByContactID
            self.lastInviteCode = nil
            self.lastErrorMessage = nil
            self.activePlaybackFile = nil
        } else {
            self.currentUser = persistedSession?.session.user
            self.deviceIdentity = nil
            self.contacts = []
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
    }

    func messages(for contact: Contact) -> [Message] {
        messagesByContactID[contact.contactID, default: []]
            .sorted { $0.createdAt < $1.createdAt }
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

        relayBaseURLString = trimmedText
        lastErrorMessage = nil
        await apiClient.updateBaseURL(url)
        persistRelayBaseURLString()
    }

    func prepareLocalIdentity() async {
        await perform {
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
            let identity = try await keyManager.loadOrCreateIdentity()
            let session = try await apiClient.register(
                username: trimmedUsername,
                deviceName: "Kithra iOS",
                encryptionPublicKey: identity.encryptionPublicKey,
                signingPublicKey: identity.signingPublicKey
            )

            await apiClient.setBearerToken(session.bearerToken)
            currentUser = session.user
            deviceIdentity = try await keyManager.bindRegisteredDeviceID(session.device.id)
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
            try await apiClient.deleteContact(contactID: contact.contactID)
            removeContactLocally(contactID: contact.contactID)
        }
    }

    func blockContact(_ contact: Contact) async {
        await perform {
            try await apiClient.blockContact(contactID: contact.contactID)
            removeContactLocally(contactID: contact.contactID)
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
        guard let activePlaybackFile else {
            return
        }

        self.activePlaybackFile = nil
        await mediaPipeline.cleanupTemporaryFiles([activePlaybackFile.url])
    }

    func sendVideo(rawVideoURL: URL, quality: DeliveryVideoQuality, to contact: Contact) async {
        await perform {
            guard let senderDeviceID = deviceIdentity?.deviceID else {
                throw DeviceKeyManagerError.identityNotFound
            }

            let compressedVideoURL = try await mediaPipeline.compressForDelivery(
                rawVideoURL: rawVideoURL,
                quality: quality
            )
            let package = try await mediaPipeline.encryptPackage(
                compressedVideoURL: compressedVideoURL,
                thumbnailURL: nil,
                recipient: contact,
                senderDeviceID: senderDeviceID,
                recipientDeviceID: contact.deviceID
            )
            var message = try await apiClient.uploadMessage(
                recipientID: contact.contactID,
                recipientDeviceID: contact.deviceID,
                envelope: package.envelope,
                encryptedBlobFileURL: package.encryptedBlobURL,
                blobSize: package.blobSize
            )
            if let localPackageURL = try? await mediaPipeline.copyLocalPackage(package.localEncryptedCopyURL, messageID: message.id) {
                message.localEncryptedPackageURL = localPackageURL
            } else {
                message.localEncryptedPackageURL = package.localEncryptedCopyURL
            }
            message.localThumbnailURL = try? await mediaPipeline.makeThumbnail(
                videoURL: compressedVideoURL,
                id: message.id
            )
            rememberLocalMedia(for: message)

            messagesByContactID[contact.contactID, default: []].append(message)
            rebuildConversations()
            let cleanupURLs = [compressedVideoURL, package.encryptedBlobURL, package.localEncryptedCopyURL]
                .filter { $0 != message.localEncryptedPackageURL }
            await mediaPipeline.cleanupTemporaryFiles(cleanupURLs)
        }
    }

    func preparePlayback(message: Message) async -> PlaybackTempFile? {
        var preparedPlaybackFile: PlaybackTempFile?

        await perform {
            var playableMessage = message
            let contactID = contactID(for: message)
            var shouldAcknowledgeDelivery = false

            if playableMessage.localEncryptedPackageURL == nil {
                if let localURL = await mediaPipeline.localEncryptedPackageURL(for: message.id) {
                    playableMessage.localEncryptedPackageURL = localURL
                    shouldAcknowledgeDelivery = message.recipientID == currentUser?.id && message.status == .sent
                } else {
                    guard message.recipientID == currentUser?.id else {
                        throw MediaPipelineError.cryptoOperationFailed("Finding a local encrypted copy for sent-message playback")
                    }
                    let downloadedBlobURL = try await apiClient.downloadMessage(id: message.id)
                    let package = try await mediaPipeline.cacheReceivedPackage(
                        message: message,
                        downloadedBlobURL: downloadedBlobURL
                    )
                    await mediaPipeline.cleanupTemporaryFiles([downloadedBlobURL])

                    playableMessage.localEncryptedPackageURL = package.localEncryptedCopyURL
                    shouldAcknowledgeDelivery = true
                    rememberLocalMedia(for: playableMessage)
                    upsert(playableMessage, contactID: contactID)
                }
            } else {
                shouldAcknowledgeDelivery = message.recipientID == currentUser?.id && message.status == .sent
            }

            guard let localEncryptedPackageURL = playableMessage.localEncryptedPackageURL else {
                throw MediaPipelineError.cryptoOperationFailed("Finding the encrypted local media package")
            }
            let package = try playbackPackage(
                for: playableMessage,
                localEncryptedPackageURL: localEncryptedPackageURL
            )
            let playbackFile = try await mediaPipeline.decryptForPlayback(package: package)
            let previousPlaybackURL = activePlaybackFile?.url
            activePlaybackFile = playbackFile
            preparedPlaybackFile = playbackFile
            if let previousPlaybackURL, previousPlaybackURL != playbackFile.url {
                await mediaPipeline.cleanupTemporaryFiles([previousPlaybackURL])
            }

            if playableMessage.localThumbnailURL == nil,
               let thumbnailURL = try? await mediaPipeline.makeThumbnail(videoURL: playbackFile.url, id: playableMessage.id) {
                playableMessage.localThumbnailURL = thumbnailURL
                rememberLocalMedia(for: playableMessage)
                upsert(playableMessage, contactID: contactID)
            }

            if shouldAcknowledgeDelivery {
                try await apiClient.acknowledgeDelivered(messageID: playableMessage.id)
                playableMessage.status = .delivered
                rememberLocalMedia(for: playableMessage)
                upsert(playableMessage, contactID: contactID)
            }
        }

        return preparedPlaybackFile
    }

    private func refreshLocalState() async throws {
        let refreshedContacts = try await apiClient.listContacts()
        let fetchedMessages = try await apiClient.listMessages()
        let messages = await hydrateLocalMedia(on: fetchedMessages)

        contacts = refreshedContacts
        messagesByContactID = group(messages: messages, contacts: refreshedContacts)
        rebuildConversations()
        await generateMissingThumbnails(for: messages)
        await cachePendingIncomingMessages(messages)
    }

    private func hydrateLocalMedia(on messages: [Message]) async -> [Message] {
        var hydratedMessages = messages
        for index in hydratedMessages.indices {
            let messageID = hydratedMessages[index].id

            if hydratedMessages[index].localEncryptedPackageURL == nil {
                if let rememberedURL = localEncryptedPackageURLs[messageID] {
                    hydratedMessages[index].localEncryptedPackageURL = rememberedURL
                } else if let cachedURL = await mediaPipeline.localEncryptedPackageURL(for: messageID) {
                    hydratedMessages[index].localEncryptedPackageURL = cachedURL
                    localEncryptedPackageURLs[messageID] = cachedURL
                }
            }

            if hydratedMessages[index].localThumbnailURL == nil {
                if let rememberedURL = localThumbnailURLs[messageID] {
                    hydratedMessages[index].localThumbnailURL = rememberedURL
                } else if let cachedURL = await mediaPipeline.localThumbnailURL(for: messageID) {
                    hydratedMessages[index].localThumbnailURL = cachedURL
                    localThumbnailURLs[messageID] = cachedURL
                }
            }
        }
        return hydratedMessages
    }

    private func cachePendingIncomingMessages(_ messages: [Message]) async {
        guard let currentUserID = currentUser?.id else {
            return
        }

        let pendingMessages = messages.filter { message in
            message.recipientID == currentUserID &&
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

    private func cacheIncomingMessage(_ message: Message) async {
        do {
            let contactID = contactID(for: message)
            let downloadedBlobURL = try await apiClient.downloadMessage(id: message.id)
            let package = try await mediaPipeline.cacheReceivedPackage(
                message: message,
                downloadedBlobURL: downloadedBlobURL
            )
            await mediaPipeline.cleanupTemporaryFiles([downloadedBlobURL])

            var cachedMessage = message
            cachedMessage.localEncryptedPackageURL = package.localEncryptedCopyURL
            rememberLocalMedia(for: cachedMessage)

            if let thumbnailURL = try await makeThumbnail(for: cachedMessage, localEncryptedPackageURL: package.localEncryptedCopyURL) {
                cachedMessage.localThumbnailURL = thumbnailURL
                rememberLocalMedia(for: cachedMessage)
            }

            upsert(cachedMessage, contactID: contactID)
            try await apiClient.acknowledgeDelivered(messageID: message.id)
            cachedMessage.status = .delivered
            upsert(cachedMessage, contactID: contactID)
        } catch {
            // Keep the relay copy visible as a playable pending tile; the next refresh can retry.
        }
    }

    private func generateMissingThumbnails(for messages: [Message]) async {
        for message in messages.prefix(12) {
            guard message.localThumbnailURL == nil,
                  let localEncryptedPackageURL = message.localEncryptedPackageURL else {
                continue
            }

            do {
                guard let thumbnailURL = try await makeThumbnail(for: message, localEncryptedPackageURL: localEncryptedPackageURL) else {
                    continue
                }

                var updatedMessage = message
                updatedMessage.localThumbnailURL = thumbnailURL
                rememberLocalMedia(for: updatedMessage)
                upsert(updatedMessage, contactID: contactID(for: message))
            } catch {
                print("Kithra thumbnail generation failed for \(message.id.uuidString): \(error.localizedDescription)")
            }
        }
    }

    private func makeThumbnail(for message: Message, localEncryptedPackageURL: URL) async throws -> URL? {
        let package = try playbackPackage(for: message, localEncryptedPackageURL: localEncryptedPackageURL)
        let playbackFile = try await mediaPipeline.decryptForPlayback(package: package)

        let thumbnailURL = try? await mediaPipeline.makeThumbnail(videoURL: playbackFile.url, id: message.id)
        await mediaPipeline.cleanupTemporaryFiles([playbackFile.url])
        return thumbnailURL
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

    private func group(messages: [Message], contacts: [Contact]) -> [UUID: [Message]] {
        let contactIDs = Set(contacts.map(\.contactID))
        var grouped: [UUID: [Message]] = [:]

        for message in messages {
            let otherID = contactIDs.contains(message.senderID) ? message.senderID : message.recipientID
            grouped[otherID, default: []].append(message)
        }

        return grouped
    }

    private func playbackPackage(for message: Message, localEncryptedPackageURL: URL) throws -> EncryptedMediaPackage {
        var playbackEnvelope = message.envelope
        if message.senderID == currentUser?.id {
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

    private func rememberLocalMedia(for message: Message) {
        if let localEncryptedPackageURL = message.localEncryptedPackageURL {
            localEncryptedPackageURLs[message.id] = localEncryptedPackageURL
        }
        if let localThumbnailURL = message.localThumbnailURL {
            localThumbnailURLs[message.id] = localThumbnailURL
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
        stopRemotePolling()
        await discardActivePlaybackFile()
        await mediaPipeline.removeAllLocalMedia()
        try? await keyManager.removeIdentity()
        await apiClient.setBearerToken(nil)

        UserDefaults.standard.removeObject(forKey: Self.persistedSessionKey)
        currentUser = nil
        deviceIdentity = nil
        contacts = []
        conversations = []
        messagesByContactID = [:]
        localEncryptedPackageURLs = [:]
        localThumbnailURLs = [:]
        lastInviteCode = nil
    }

    private func restore(_ persistedSession: PersistedAuthSession) async {
        guard let relayURL = URL(string: persistedSession.relayBaseURLString) else {
            return
        }

        await apiClient.updateBaseURL(relayURL)
        await apiClient.setBearerToken(persistedSession.session.bearerToken)

        await perform {
            deviceIdentity = try await keyManager.currentIdentity()
            try await refreshLocalState()
        }
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
