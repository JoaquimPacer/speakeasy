import Foundation
import SwiftUI
#if DEBUG
import Sodium
#endif

@MainActor
final class AppState: ObservableObject {
    private static let relayBaseURLKey = "speakeasy.relayBaseURL.v1"
    private static let localDefaultRelayURL = URL(string: "http://localhost:8080")!
    private static let publicDefaultRelayURL = URL(string: "https://api.jqinnovation.com")!

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
    @Published private(set) var needsLocalCleanupRetry = false
    @Published private(set) var needsAccountDeletionRetry = false
    @Published private(set) var isAccountDeletionIntentStorageUncertain = false
    @Published private(set) var needsAuthenticationStorageReload = false
    @Published private(set) var needsAuthenticationRecoveryRetry = false
    @Published private(set) var isRestoringSession = false
    @Published private(set) var isRegistrationInFlight = false

    let apiClient: SpeakeasyAPIClient
    let keyManager: DeviceKeyManaging
    let mediaPipeline: MediaPipelining
    let contactTrustStore: ContactTrustStoring
    let messageReplayStore: MessageReplayStoring
    private let sessionStore: AuthSessionStoring
    private let pendingRegistrationStore: PendingRegistrationStoring
    private let accountDeletionIntentStore: AccountDeletionIntentStoring
    private let preferences: UserDefaults
    private let bootstrapMarkers: LocalAccountBootstrapMarkers
    private let messageAuthenticator: MessageEnvelopeAuthenticator
    private var isRefreshingQuietly = false
    private var localEncryptedPackageURLs: [LocalEncryptedMediaIdentifier: URL] = [:]
    private var localThumbnailURLs: [AuthenticatedThumbnailIdentifier: URL] = [:]
    private var remotePollingTask: Task<Void, Never>?
    private var playbackCleanupTask: Task<Void, Never>?
    private var playbackPreparationGeneration: UInt64 = 0
    private var playbackPreparationPermits: [UUID: PlaybackPreparationPermit] = [:]
    private var allowsPlaybackPreparation = false
    private var plaintextProductionGeneration: UInt64 = 0
    private var plaintextProductionPermits: [UUID: ForegroundPlaintextPermit] = [:]
    private var allowsPlaintextProduction = false
    private var invalidatedPlaintextURLsPendingCleanup: [URL] = []
    private var requiresFreshInstallKeychainReset: Bool
    private var activeIncomingReceiptOperations: Set<IncomingReceiptOperationKey> = []
    private var isClearingLocalAccountState = false
    private var accountStateGeneration: UInt64 = 0
    private var storedAuthSession: StoredAuthSession?
    private var pendingRegistration: PendingRegistrationRecord?
    private var pendingAccountDeletion: PendingAccountDeletionRecord?
    private var sessionRenewalTask: Task<AuthSession, Error>?
    private var registrationTask: Task<Void, Never>?
    private var registrationAttemptID: UUID?
    private var registrationAttemptUsername: String?
    private let registrationDeviceIDProvider: () -> UUID
#if DEBUG
    private(set) var isScreenshotPreview: Bool
    private let screenshotPreviewSigningPrivateKey: Data?
#endif

    var isAuthenticationBootstrapUncertain: Bool {
        needsLocalCleanupRetry
            || needsAccountDeletionRetry
            || isAccountDeletionIntentStorageUncertain
            || needsAuthenticationStorageReload
            || needsAuthenticationRecoveryRetry
            || isRestoringSession
    }

    var isSetupMutationBlocked: Bool {
        isWorking || isRegistrationInFlight || isAuthenticationBootstrapUncertain
    }

    /// A first registration with no authenticated response may already exist
    /// on the relay. Erasing its durable intent and signing key would strand
    /// that account permanently, so recovery must reach a definitive outcome
    /// before local reset is allowed.
    var isPendingRegistrationResetBlocked: Bool {
        guard let pendingRegistration else {
            return false
        }
        return pendingRegistration.session == nil
    }

    init(
        relayBaseURL: URL? = nil,
        apiClient: SpeakeasyAPIClient? = nil,
        keyManager: DeviceKeyManaging = KeychainDeviceKeyManager(),
        mediaPipeline: MediaPipelining = DefaultMediaPipeline(),
        contactTrustStore: ContactTrustStoring = KeychainContactTrustStore(),
        messageReplayStore: MessageReplayStoring = KeychainMessageReplayStore(),
        sessionStore: AuthSessionStoring = KeychainAuthSessionStore(),
        pendingRegistrationStore: PendingRegistrationStoring = KeychainPendingRegistrationStore(),
        accountDeletionIntentStore: AccountDeletionIntentStoring = KeychainAccountDeletionIntentStore(),
        registrationDeviceIDProvider: @escaping () -> UUID = { UUID() },
        preferences: UserDefaults = .standard,
        messageAuthenticator: MessageEnvelopeAuthenticator = MessageEnvelopeAuthenticator(),
        seedPreviewData: Bool = true
    ) {
#if DEBUG
        let isScreenshotPreview = ProcessInfo.processInfo.arguments.contains(
            "--kithra-screenshot-preview"
        )
        let screenshotPreviewSigningKeyPair = isScreenshotPreview
            ? Sodium().sign.keyPair()
            : nil
        self.isScreenshotPreview = isScreenshotPreview
        self.screenshotPreviewSigningPrivateKey = screenshotPreviewSigningKeyPair
            .map { Data($0.secretKey) }
#endif
        self.sessionStore = sessionStore
        self.pendingRegistrationStore = pendingRegistrationStore
        self.accountDeletionIntentStore = accountDeletionIntentStore
        self.registrationDeviceIDProvider = registrationDeviceIDProvider
        self.preferences = preferences

        let bootstrapMarkers = LocalAccountBootstrapMarkers(preferences: preferences)
        self.bootstrapMarkers = bootstrapMarkers
        var persistedAccountDeletion: PendingAccountDeletionRecord?
        var accountDeletionBootstrapError: Error?
        if !seedPreviewData {
            do {
                persistedAccountDeletion = try accountDeletionIntentStore.load()
            } catch {
                accountDeletionBootstrapError = error
            }
        }
        let bootstrapPlan = seedPreviewData
            ? LocalAccountBootstrapPlan(mode: .existingInstall)
            : bootstrapMarkers.plan(
                hasProtectedAccountDeletionIntent: persistedAccountDeletion != nil
            )
        var persistedSession: StoredAuthSession?
        var persistedPendingRegistration: PendingRegistrationRecord?
        var sessionBootstrapError: Error?
        var pendingRegistrationBootstrapError: Error?
        if !seedPreviewData {
            do {
                persistedSession = try LocalAccountSessionBootstrap.loadOrMigrate(
                    plan: bootstrapPlan,
                    legacySessionData: bootstrapMarkers.legacySessionData,
                    sessionStore: sessionStore,
                    decodeLegacySession: Self.decodeLegacyPersistedSession
                ) { verifiedSession in
                    // Record the in-place-upgrade classification before
                    // deleting the only signal that distinguishes it from a
                    // reinstall whose Keychain items survived app removal.
                    bootstrapMarkers.preserveExistingInstallClassification()
                    preferences.set(verifiedSession.relayBaseURLString, forKey: Self.relayBaseURLKey)
                    bootstrapMarkers.discardLegacySession()
                }
            } catch {
                sessionBootstrapError = error
            }
            if bootstrapPlan.permitsProtectedSessionRestore {
                do {
                    persistedPendingRegistration = try pendingRegistrationStore.load()
                } catch {
                    pendingRegistrationBootstrapError = error
                }
            }
            if sessionBootstrapError == nil,
               pendingRegistrationBootstrapError == nil,
               let persistedSession,
               let persistedPendingRegistration,
               !PendingRegistrationRecovery.isCompatible(
                    persistedSession,
                    with: persistedPendingRegistration
               ) {
                pendingRegistrationBootstrapError = AuthSessionStoreError.conflictingRegistrationRecovery
            }

            // Never choose one authority when the other protected namespace
            // could not be read or the two records conflict. A later reload
            // reconciles both stores together without erasing either record.
            if sessionBootstrapError != nil
                || pendingRegistrationBootstrapError != nil
                || accountDeletionBootstrapError != nil {
                persistedSession = nil
                persistedPendingRegistration = nil
                if accountDeletionBootstrapError != nil {
                    persistedAccountDeletion = nil
                }
            }
        }
        let registrationUncertaintyWithoutAuthority = bootstrapPlan.requiresRegistrationReconciliation
            && persistedSession == nil
            && persistedPendingRegistration == nil
            && sessionBootstrapError == nil
            && pendingRegistrationBootstrapError == nil
        let initializationError = accountDeletionBootstrapError
            ?? sessionBootstrapError
            ?? pendingRegistrationBootstrapError
            ?? (registrationUncertaintyWithoutAuthority
                ? AuthSessionStoreError.ambiguousRegistrationRecovery
                : nil)

        let preferredRelayURL: URL
#if DEBUG
        if isScreenshotPreview {
            // Screenshot fixtures must never inherit a developer's persisted
            // localhost relay or contact a relay while presenting sample data.
            preferredRelayURL = Self.publicDefaultRelayURL
        } else {
            preferredRelayURL = relayBaseURL
                ?? persistedPendingRegistration.flatMap { URL(string: $0.relayBaseURLString) }
                ?? persistedSession.flatMap { URL(string: $0.relayBaseURLString) }
                ?? preferences.string(forKey: Self.relayBaseURLKey).flatMap(URL.init(string:))
                ?? Self.bundledDefaultRelayURL
        }
#else
        preferredRelayURL = relayBaseURL
            ?? persistedPendingRegistration.flatMap { URL(string: $0.relayBaseURLString) }
            ?? persistedSession.flatMap { URL(string: $0.relayBaseURLString) }
            ?? preferences.string(forKey: Self.relayBaseURLKey).flatMap(URL.init(string:))
            ?? Self.bundledDefaultRelayURL
#endif
        let safeAPIBaseURL = RelayURLPolicy.allows(preferredRelayURL)
            ? preferredRelayURL
            : Self.bundledDefaultRelayURL
        self.relayBaseURLString = (persistedSession == nil ? safeAPIBaseURL : preferredRelayURL).absoluteString
        self.apiClient = apiClient ?? SpeakeasyAPIClient(configuration: APIConfiguration(baseURL: safeAPIBaseURL))
        self.keyManager = keyManager
        self.mediaPipeline = mediaPipeline
        self.contactTrustStore = contactTrustStore
        self.messageReplayStore = messageReplayStore
        self.messageAuthenticator = messageAuthenticator
        self.storedAuthSession = persistedSession
        self.pendingRegistration = persistedPendingRegistration
        self.pendingAccountDeletion = persistedAccountDeletion
        self.requiresFreshInstallKeychainReset = !seedPreviewData
            && bootstrapPlan.requiresCleanupBeforeIdentityCreation

        if seedPreviewData {
            var preview = PreviewData.sample
#if DEBUG
            if isScreenshotPreview, let signingPublicKey = screenshotPreviewSigningKeyPair
                .map({ Data($0.publicKey) }) {
                // Use an ephemeral in-memory signing key so the sample QR is a
                // genuinely signed payload without reading or writing Keychain.
                preview.deviceIdentity.signingPublicKey = signingPublicKey
            }
#endif
            self.currentUser = preview.currentUser
            self.deviceIdentity = preview.deviceIdentity
            self.contacts = preview.contacts
            var previewTrustAssessments: [UUID: ContactTrustAssessment] = [:]
#if DEBUG
            if isScreenshotPreview {
                previewTrustAssessments = Dictionary(
                    uniqueKeysWithValues: preview.contacts.compactMap { contact in
                        guard let context = try? ContactVerificationContext(
                            relayURL: safeAPIBaseURL,
                            localUser: preview.currentUser,
                            localDeviceIdentity: preview.deviceIdentity,
                            contact: contact
                        ) else {
                            return nil
                        }
                        return (
                            contact.contactID,
                            ContactTrustAssessment(
                                state: .verified,
                                candidateIdentity: context.remoteIdentity,
                                trustedIdentity: context.remoteIdentity,
                                verificationMethod: .safetyNumberComparison,
                                verifiedAt: preview.currentUser.createdAt
                            )
                        )
                    }
                )
            }
#endif
            self.contactTrustAssessments = previewTrustAssessments
            self.conversations = preview.conversations
            self.messagesByContactID = preview.messagesByContactID
            self.lastInviteCode = nil
            self.lastErrorMessage = initializationError?.localizedDescription
            self.activePlaybackFile = nil
        } else {
            // Publish no authenticated UI state until restore has validated the
            // protected identity and installed the matching API authority.
            self.currentUser = nil
            self.deviceIdentity = nil
            self.contacts = []
            self.contactTrustAssessments = [:]
            self.conversations = []
            self.messagesByContactID = [:]
            self.lastInviteCode = nil
            self.lastErrorMessage = initializationError?.localizedDescription
            self.activePlaybackFile = nil
        }
        self.needsLocalCleanupRetry = bootstrapPlan.requiresVisibleCleanupRetry
        self.needsAccountDeletionRetry = persistedAccountDeletion != nil
        self.isAccountDeletionIntentStorageUncertain = accountDeletionBootstrapError != nil
        let authenticationStorageLoadFailedAtInitialization = initializationError != nil
        self.needsAuthenticationStorageReload = authenticationStorageLoadFailedAtInitialization
        self.needsAuthenticationRecoveryRetry = false
        self.isRestoringSession = !self.needsAuthenticationStorageReload
            && (persistedAccountDeletion != nil
                || persistedSession != nil
                || persistedPendingRegistration != nil)

        if persistedAccountDeletion != nil || accountDeletionBootstrapError != nil {
            mediaPipeline.closePlaintextProductionForAccountDeletion()
        }

        if !seedPreviewData {
            Task { [weak self] in
                guard let self else {
                    return
                }
                await self.apiClient.setAuthenticationRecoveryHandler { [weak self] in
                    guard let self else {
                        throw APIClientError.authenticationRecoveryUnavailable
                    }
                    return try await self.renewSession()
                }
                // Use the immutable bootstrap result. A user-triggered reload
                // can clear the published flag before this startup task gets
                // scheduled; consulting that mutable flag here would then
                // start a second deletion reconciliation alongside the retry.
                if authenticationStorageLoadFailedAtInitialization {
                    self.isRestoringSession = false
                } else if persistedAccountDeletion != nil {
                    await self.resumePendingAccountDeletion()
                } else if let persistedPendingRegistration,
                   sessionBootstrapError == nil,
                   pendingRegistrationBootstrapError == nil {
                    await self.restorePendingRegistration(persistedPendingRegistration)
                } else if let persistedSession,
                          sessionBootstrapError == nil,
                          pendingRegistrationBootstrapError == nil {
                    await self.restore(persistedSession)
                } else {
                    self.isRestoringSession = false
                }
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
#if DEBUG
        if isScreenshotPreview,
           let signingPrivateKey = screenshotPreviewSigningPrivateKey {
            do {
                let context = try makeVerificationContext(for: contact)
                let signingBytes = try ContactVerificationQRPayload.signingBytes(
                    presenterIdentity: context.localIdentity,
                    expectedPeerIdentity: context.remoteIdentity
                )
                guard let signature = Sodium().sign.signature(
                    message: Array(signingBytes),
                    secretKey: Array(signingPrivateKey)
                ) else {
                    return nil
                }
                return try ContactVerificationQRPayload(
                    presenterIdentity: context.localIdentity,
                    expectedPeerIdentity: context.remoteIdentity,
                    signature: Data(signature)
                ).encodedString
            } catch {
                return nil
            }
        }
#endif
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
        guard !isAuthenticationBootstrapUncertain else {
            lastErrorMessage = AuthenticationBootstrapBlockedError().localizedDescription
            return
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedText),
              RelayURLPolicy.allows(url) else {
#if DEBUG
            lastErrorMessage = "Use HTTPS, or a local/private HTTP relay for Debug development."
#else
            lastErrorMessage = "Public release builds require an HTTPS relay URL."
#endif
            return
        }
        if (currentUser != nil
                || storedAuthSession != nil
                || pendingRegistration != nil
                || isRegistrationInFlight),
           trimmedText != relayBaseURLString {
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
            try ensureAuthenticationBootstrapReadyForMutation()
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

        if let registrationTask {
            guard registrationAttemptUsername == trimmedUsername else {
                lastErrorMessage = "Registration for \(registrationAttemptUsername ?? "this account") is already in progress. Wait for it to finish before using another username."
                return
            }
            await registrationTask.value
            return
        }

        let attemptID = UUID()
        registrationAttemptID = attemptID
        registrationAttemptUsername = trimmedUsername
        isRegistrationInFlight = true
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.perform {
                try await self.performRegistration(username: trimmedUsername)
            }
        }
        registrationTask = task
        await task.value
        if registrationAttemptID == attemptID {
            registrationTask = nil
            registrationAttemptID = nil
            registrationAttemptUsername = nil
            isRegistrationInFlight = false
        }
    }

    private func performRegistration(username: String) async throws {
        if let pendingRegistration {
            guard pendingRegistration.username == username else {
                throw RegistrationRecoveryError.usernameMismatch(
                    expected: pendingRegistration.username
                )
            }
            do {
                try await completePendingRegistration(pendingRegistration)
                needsAuthenticationRecoveryRetry = false
            } catch {
                recordAuthenticationRecoveryFailure(error)
                await suspendPublishedAuthenticationForRetry()
                throw error
            }
            return
        }
        if let storedAuthSession, currentUser == nil {
            guard storedAuthSession.session.user.username == username else {
                throw RegistrationRecoveryError.usernameMismatch(
                    expected: storedAuthSession.session.user.username
                )
            }
            do {
                try await completeProtectedRegistration(
                    storedAuthSession,
                    requestedUsername: username
                )
                needsAuthenticationRecoveryRetry = false
            } catch {
                recordAuthenticationRecoveryFailure(error)
                await suspendPublishedAuthenticationForRetry()
                throw error
            }
            return
        }

        try ensureAuthenticationBootstrapReadyForMutation()
        try await clearResidualKeychainAfterFreshInstallIfNeeded()
        let identity = try await keyManager.loadOrCreateIdentity()
        guard identity.deviceID == nil else {
            throw ContactMessagingSecurityError.localIdentityAlreadyBound
        }
        let registrationGeneration = accountStateGeneration
        let registrationRelay = relayBaseURLString
        let pendingRecord = PendingRegistrationRecord(
            relayBaseURLString: registrationRelay,
            username: username,
            deviceID: registrationDeviceIDProvider(),
            deviceName: "Kithra iOS",
            expectedIdentity: PendingRegistrationIdentity(identity)
        )
        // The client-generated device ID and exact registration inputs must be
        // durable before the relay can commit anything. A timeout or process
        // death can then replay this same identity and recover through signed
        // login instead of creating a ghost account with a new device ID.
        try PendingRegistrationPersistence.saveAndVerify(
            pendingRecord,
            in: pendingRegistrationStore
        )
        guard accountStateGeneration == registrationGeneration,
              !isClearingLocalAccountState,
              relayBaseURLString == registrationRelay,
              let currentIdentity = try await keyManager.currentIdentity(),
              currentIdentity == identity else {
            // Leave the verified intent protected for explicit reconciliation.
            throw AuthSessionValidationError.noRecoverableSession
        }
        pendingRegistration = pendingRecord
        bootstrapMarkers.markRegistrationUncertain()
        do {
            try await completePendingRegistration(pendingRecord)
            needsAuthenticationRecoveryRetry = false
        } catch {
            recordAuthenticationRecoveryFailure(error)
            await suspendPublishedAuthenticationForRetry()
            throw error
        }
    }

    /// Reloads both protected authentication namespaces as one authority. This
    /// path never removes keys, sessions, or pending records. A verified legacy
    /// bearer is removed only after its matching Keychain copy passes readback.
    func retryAuthenticationStorageLoad() async {
        guard !isRestoringSession, !needsLocalCleanupRetry else {
            return
        }

        isRestoringSession = true
        needsAuthenticationStorageReload = false
        var reloadedSession: StoredAuthSession?
        var reloadedPending: PendingRegistrationRecord?
        var reloadedAccountDeletion: PendingAccountDeletionRecord?
        let loaded = await perform {
            let records = try loadProtectedAuthenticationRecords()
            reloadedSession = records.session
            reloadedPending = records.pending
            reloadedAccountDeletion = records.accountDeletion
        }
        guard loaded else {
            needsAuthenticationStorageReload = true
            isRestoringSession = false
            return
        }

        storedAuthSession = reloadedSession
        pendingRegistration = reloadedPending
        pendingAccountDeletion = reloadedAccountDeletion
        needsAccountDeletionRetry = reloadedAccountDeletion != nil
        if reloadedAccountDeletion == nil {
            mediaPipeline.reopenPlaintextProductionAfterAccountDeletionEnds()
        } else {
            mediaPipeline.closePlaintextProductionForAccountDeletion()
        }
        if let protectedRelay = reloadedPending?.relayBaseURLString
            ?? reloadedSession?.relayBaseURLString {
            relayBaseURLString = protectedRelay
        }

        if reloadedAccountDeletion != nil {
            needsAccountDeletionRetry = true
            await resumePendingAccountDeletion()
        } else if let reloadedPending {
            await restorePendingRegistration(reloadedPending)
        } else if let reloadedSession {
            await restore(reloadedSession)
        } else {
            isRestoringSession = false
            needsAuthenticationRecoveryRetry = false
            lastErrorMessage = nil
        }
    }

    /// When a prior local cleanup marker is already authoritative, only reload
    /// the deletion-intent namespace. This cannot restore a bearer or publish
    /// signed-in UI, but it resolves a locked-Keychain deadlock after unlock.
    func retryAccountDeletionIntentStorageLoad() async {
        guard isAccountDeletionIntentStorageUncertain,
              needsLocalCleanupRetry,
              !isRestoringSession else {
            return
        }
        isRestoringSession = true
        var reloadedIntent: PendingAccountDeletionRecord?
        let loaded = await perform {
            reloadedIntent = try accountDeletionIntentStore.load()
        }
        guard loaded else {
            isRestoringSession = false
            return
        }

        isAccountDeletionIntentStorageUncertain = false
        needsAuthenticationStorageReload = false
        pendingAccountDeletion = reloadedIntent
        needsAccountDeletionRetry = reloadedIntent != nil
        if reloadedIntent != nil {
            await resumePendingAccountDeletion()
        } else {
            isRestoringSession = false
            lastErrorMessage = nil
        }
    }

    func retryAuthenticationRecovery() async {
        guard !isRestoringSession else {
            return
        }
        if pendingAccountDeletion != nil {
            await retryPendingAccountDeletion()
            return
        }
        if needsAuthenticationStorageReload {
            await retryAuthenticationStorageLoad()
            return
        }
        isRestoringSession = true
        needsAuthenticationRecoveryRetry = false
        if let pendingRegistration {
            await restorePendingRegistration(pendingRegistration)
        } else if let storedAuthSession {
            await restore(storedAuthSession)
        } else {
            isRestoringSession = false
            lastErrorMessage = AuthSessionValidationError.noRecoverableSession.localizedDescription
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
#if DEBUG
        guard !isScreenshotPreview else {
            return
        }
#endif
        await perform {
            try await refreshLocalState()
        }
    }

    func refreshQuietly() async {
#if DEBUG
        guard !isScreenshotPreview else {
            return
        }
#endif
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
#if DEBUG
        guard !isScreenshotPreview else {
            stopRemotePolling()
            return
        }
#endif
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
            guard currentUser != nil,
                  let protectedSession = storedAuthSession else {
                throw AccountDeletionRecoveryError.missingProtectedSession
            }
            let identity: DevicePublicIdentity
            if let deviceIdentity {
                identity = deviceIdentity
            } else if let storedIdentity = try await keyManager.currentIdentity() {
                identity = storedIdentity
            } else {
                throw AccountDeletionRecoveryError.missingDeviceIdentity
            }
            try AuthSessionValidator.validateStoredRecoveryAuthority(
                protectedSession.session,
                requestedUsername: protectedSession.session.user.username,
                localIdentity: identity
            )
            let deletionIntent = PendingAccountDeletionRecord(
                protectedSession: protectedSession,
                identity: identity
            )
            // Close the shared producer gate before persistence. If Keychain
            // commit/readback is ambiguous, the gate stays closed until an
            // exact reload proves there is no durable deletion intent.
            mediaPipeline.closePlaintextProductionForAccountDeletion()
            // Keychain save plus exact readback must finish before DELETE can
            // reach the relay. The record survives process death and reinstall.
            do {
                try AccountDeletionIntentPersistence.saveAndVerify(
                    deletionIntent,
                    in: accountDeletionIntentStore
                )
            } catch {
                // A Keychain save can commit and still fail readback. Treat the
                // namespace as unknown, hide active UI, and forbid local reset
                // until a later exact reload proves whether the intent exists.
                isAccountDeletionIntentStorageUncertain = true
                needsAuthenticationStorageReload = true
                needsAccountDeletionRetry = true
                suspendPublishedAuthenticationForAccountDeletion()
                await apiClient.setAuthSession(nil)
                try? await removeInvalidatedPlaintextFiles()
                throw error
            }
            pendingAccountDeletion = deletionIntent
            needsAccountDeletionRetry = true
            suspendPublishedAuthenticationForAccountDeletion()
            try await reconcilePendingAccountDeletion()
        }
    }

    func retryPendingAccountDeletion() async {
        guard pendingAccountDeletion != nil,
              !isRestoringSession,
              !isClearingLocalAccountState else {
            return
        }
        if needsAuthenticationStorageReload {
            await retryAuthenticationStorageLoad()
            return
        }
        isRestoringSession = true
        await resumePendingAccountDeletion()
    }

    func resetLocalRegistration(
        confirmation: LocalRegistrationResetConfirmation
    ) async {
        guard confirmation == .eraseProtectedLocalAccount else {
            return
        }
        guard !isAccountDeletionIntentStorageUncertain else {
            lastErrorMessage = "Reload the protected account-deletion record before resetting this device. Kithra will not erase the signing key while deletion state is unreadable."
            return
        }
        guard pendingAccountDeletion == nil else {
            lastErrorMessage = "Retry the confirmed account deletion before resetting this device. Kithra must keep its signing key until the relay deletion is definitive."
            return
        }
        guard !isPendingRegistrationResetBlocked else {
            lastErrorMessage = "Retry protected account recovery before resetting this device. The relay may already have accepted this registration, so Kithra must keep its signing key."
            return
        }
        await perform {
            // If the relay is reachable, revoke the server-side bearer before
            // erasing the signing identity that could renew it. Local cleanup
            // still completes offline; any surviving server session is short-
            // lived and expires independently.
            try? await apiClient.logout()
            try await clearLocalAccountState()
        }
    }

    func discardActivePlaybackFile() async {
        playbackPreparationGeneration &+= 1
        var cleanupURLs = playbackPreparationPermits.values.flatMap { $0.invalidate() }
        playbackCleanupTask?.cancel()
        playbackCleanupTask = nil
        if let activePlaybackFile {
            cleanupURLs.append(activePlaybackFile.url)
        }

        self.activePlaybackFile = nil
        await mediaPipeline.cleanupTemporaryFiles(uniqueURLs(cleanupURLs))
    }

    func resumePlaintextProductionAfterBecomingActive() {
        guard pendingAccountDeletion == nil,
              !isAccountDeletionIntentStorageUncertain,
              !needsLocalCleanupRetry,
              !isClearingLocalAccountState else {
            return
        }
        mediaPipeline.reopenPlaintextProductionAfterAccountDeletionEnds()
        allowsPlaybackPreparation = true
        allowsPlaintextProduction = true
    }

#if DEBUG
    func installPlaybackPreparationPermitForTesting(
        _ permit: PlaybackPreparationPermit
    ) {
        allowsPlaybackPreparation = true
        playbackPreparationPermits[permit.id] = permit
    }

    var isPlaintextProductionEnabledForTesting: Bool {
        allowsPlaybackPreparation || allowsPlaintextProduction
    }
#endif

    func invalidatePlaintextProductionForBackground() {
        allowsPlaybackPreparation = false
        playbackPreparationGeneration &+= 1
        allowsPlaintextProduction = false
        plaintextProductionGeneration &+= 1

        var cleanupURLs = playbackPreparationPermits.values.flatMap { $0.invalidate() }
        cleanupURLs.append(
            contentsOf: plaintextProductionPermits.values.flatMap { $0.invalidate() }
        )
        playbackCleanupTask?.cancel()
        playbackCleanupTask = nil
        if let activePlaybackFile {
            cleanupURLs.append(activePlaybackFile.url)
        }
        activePlaybackFile = nil
        cleanupURLs.append(contentsOf: clearLocalThumbnailReferencesForBackground())

        invalidatedPlaintextURLsPendingCleanup.append(contentsOf: cleanupURLs)
        invalidatedPlaintextURLsPendingCleanup = uniqueURLs(
            invalidatedPlaintextURLsPendingCleanup
        )
    }

    func cleanupInvalidatedPlaintextFiles() async {
        try? await removeInvalidatedPlaintextFiles()
    }

    private func removeInvalidatedPlaintextFiles() async throws {
        let cleanupURLs = invalidatedPlaintextURLsPendingCleanup
        invalidatedPlaintextURLsPendingCleanup.removeAll()
        do {
            try await mediaPipeline.removePlaintextTemporaryFiles(cleanupURLs)
        } catch {
            // Keep exact paths queued so foreground recovery or the next scene
            // transition retries deletion instead of relying only on relaunch.
            invalidatedPlaintextURLsPendingCleanup.append(contentsOf: cleanupURLs)
            invalidatedPlaintextURLsPendingCleanup = uniqueURLs(
                invalidatedPlaintextURLsPendingCleanup
            )
            throw error
        }
    }

    func sendVideo(
        rawVideoURL: URL,
        quality: DeliveryVideoQuality,
        to contact: Contact,
        onPlaintextOwnershipAccepted: (() -> Void)? = nil
    ) async {
        guard let plaintextPreparation = beginPlaintextProduction(
            tracking: [rawVideoURL]
        ) else {
            try? await mediaPipeline.removePlaintextTemporaryFiles([rawVideoURL])
            onPlaintextOwnershipAccepted?()
            return
        }
        // No actor suspension occurs between installing this AppState permit
        // and releasing the producer's prior ownership, so scene invalidation
        // always sees at least one exact-path owner during the handoff.
        onPlaintextOwnershipAccepted?()
        defer { finishPlaintextProduction(plaintextPreparation.permit) }

        var plaintextURLsPendingCleanup = [rawVideoURL]
        await perform {
            try requirePlaintextProduction(plaintextPreparation)
            guard let currentUser, let senderDeviceID = deviceIdentity?.deviceID else {
                throw DeviceKeyManagerError.identityNotFound
            }
            var generatedPackage: EncryptedMediaPackage?
            var durableLocalPackageURL: URL?
            var durableOutgoingClientMessageID: UUID?
            var generatedThumbnailURL: URL?
            var uploadStarted = false

            do {
                let compressedVideoURL = try await mediaPipeline.compressForDelivery(
                    rawVideoURL: rawVideoURL,
                    quality: quality,
                    permit: plaintextPreparation.permit
                )
                plaintextURLsPendingCleanup.append(compressedVideoURL)
                try requirePlaintextProduction(plaintextPreparation)

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
                try requirePlaintextProduction(plaintextPreparation)
                try EncryptedMediaUploadPolicy.validate(
                    fileURL: package.encryptedBlobURL,
                    declaredBlobSize: package.blobSize
                )

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
                durableOutgoingClientMessageID = clientMessageID
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
                try requirePlaintextProduction(plaintextPreparation)

                // The thumbnail is derived before the delivery video is erased,
                // and is bound to the signed client message ID rather than a
                // relay-selected identifier.
                generatedThumbnailURL = try await mediaPipeline.makeThumbnail(
                    videoURL: compressedVideoURL,
                    identifier: thumbnailIdentifier,
                    permit: plaintextPreparation.permit
                )
                try requirePlaintextProduction(plaintextPreparation)

                // Durable persistence and thumbnail generation suspend. Recheck
                // both exact identities before retaining their output.
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

                // From this point forward upload and retry need ciphertext only.
                // Abort before contacting the relay unless every raw/compressed
                // plaintext input has been synchronously removed.
                try await mediaPipeline.removePlaintextTemporaryFiles(
                    plaintextURLsPendingCleanup
                )
                plaintextURLsPendingCleanup.removeAll()

                // Plaintext deletion is an async protocol boundary. Recheck once
                // more immediately before the relay receives ciphertext.
                guard self.currentUser?.id == currentUser.id,
                      deviceIdentity?.deviceID == senderDeviceID else {
                    throw ContactMessagingSecurityError.localIdentityMismatch
                }
                let postCleanupVerification = try verifiedRecipient(for: contact.contactID)
                guard postCleanupVerification.recipient.constantTimeEquals(
                    initialVerification.recipient
                ), postCleanupVerification.context.localIdentity.constantTimeEquals(
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
                let publicationVerification = try verifiedRecipient(for: contact.contactID)
                guard publicationVerification.recipient.constantTimeEquals(
                    initialVerification.recipient
                ), publicationVerification.context.localIdentity.constantTimeEquals(
                    initialVerification.context.localIdentity
                ) else {
                    throw ContactMessagingSecurityError.identityChangedDuringSend
                }
                if plaintextPreparation.permit.isValid {
                    message.localThumbnailURL = generatedThumbnailURL
                } else {
                    if let generatedThumbnailURL {
                        await mediaPipeline.cleanupTemporaryFiles([generatedThumbnailURL])
                    }
                    generatedThumbnailURL = nil
                    message.localThumbnailURL = nil
                }
                rememberLocalMedia(
                    for: message,
                    encryptedIdentifier: encryptedIdentifier,
                    thumbnailIdentifier: thumbnailIdentifier
                )

                messagesByContactID[initialVerification.recipient.userID, default: []].append(message)
                rebuildConversations()
                generatedThumbnailURL = nil
                let cleanupURLs = [package.encryptedBlobURL, package.localEncryptedCopyURL]
                    .filter { $0 != message.localEncryptedPackageURL }
                await mediaPipeline.cleanupTemporaryFiles(cleanupURLs)
            } catch {
                var surfacedError: Error = error
                do {
                    try await mediaPipeline.removePlaintextTemporaryFiles(
                        plaintextURLsPendingCleanup
                    )
                    plaintextURLsPendingCleanup.removeAll()
                } catch {
                    surfacedError = MediaSendPlaintextCleanupError(
                        sendDetail: surfacedError.localizedDescription,
                        cleanupDetail: error.localizedDescription
                    )
                }
                let definitelyNotAccepted: Bool
                if !uploadStarted || error is EncryptedMediaUploadPolicyError {
                    definitelyNotAccepted = true
                } else if let apiError = error as? APIClientError {
                    definitelyNotAccepted = apiError.uploadWasDefinitelyNotAccepted
                } else {
                    definitelyNotAccepted = false
                }

                if definitelyNotAccepted,
                   durableLocalPackageURL != nil,
                   let durableOutgoingClientMessageID {
                    do {
                        try await mediaPipeline.removeLocalEncryptedPackage(
                            for: .outgoingClientMessage(durableOutgoingClientMessageID)
                        )
                        durableLocalPackageURL = nil
                    } catch {
                        surfacedError = DefinitiveUploadLocalCleanupError(
                            uploadDetail: surfacedError.localizedDescription,
                            cleanupDetail: error.localizedDescription
                        )
                    }
                }

                var cleanupURLs: [URL] = []
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
                // accepted signed envelope without duplicating the send. Known
                // local/preflight failures and relay 413/507 rejections remove
                // that copy through the throwing path above.
                await mediaPipeline.cleanupTemporaryFiles(cleanupURLs)
                throw surfacedError
            }
        }

        // `perform` intentionally skips work while account cleanup is active.
        // The captured raw file still belongs to this call and must never be
        // left behind in that case (or after a failed first cleanup attempt).
        if !plaintextURLsPendingCleanup.isEmpty {
            do {
                try await mediaPipeline.removePlaintextTemporaryFiles(
                    plaintextURLsPendingCleanup
                )
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func preparePlayback(message: Message) async -> PlaybackTempFile? {
        guard let preparation = beginPlaybackPreparation() else {
            return nil
        }
        defer { finishPlaybackPreparation(preparation.permit) }

        var preparedPlaybackFile: PlaybackTempFile?

        await perform {
            try requirePlaybackPreparation(preparation)
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
                        try requirePlaybackPreparation(preparation)
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
                        try requirePlaybackPreparation(preparation)
                        do {
                            let stagedPackage = try await mediaPipeline.stageReceivedPackage(
                                message: message,
                                downloadedBlobURL: downloadedBlobURL
                            )
                            stagedReceivedPackage = stagedPackage
                            try requirePlaybackPreparation(preparation)
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
                        try requirePlaybackPreparation(preparation)
                        guard let stagedPackage = stagedReceivedPackage else {
                            throw MediaPipelineError.stagedPackageMissing
                        }
                        let package = try await mediaPipeline.commitStagedReceivedPackage(
                            stagedPackage,
                            allowExistingExactRecovery: reservation == .recoveringPending
                        )
                        try requirePlaybackPreparation(preparation)
                        stagedReceivedPackage = nil
                        let commitSecurity = try authenticateIncomingMessage(message)
                        try await markNetworkReceiptCommitted(
                            message: message,
                            security: commitSecurity
                        )
                        try requirePlaybackPreparation(preparation)
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
                    try requirePlaybackPreparation(preparation)
                    let currentSecurity = try authenticateIncomingMessage(playableMessage)
                    try await validateLocalReceipt(
                        message: playableMessage,
                        security: currentSecurity
                    )
                    try requirePlaybackPreparation(preparation)
                }
                try requirePlaybackPreparation(preparation)
                try reauthenticateMessageDirection(
                    playableMessage,
                    expected: authenticatedDirection
                )
                let playbackFile = try await mediaPipeline.decryptForPlayback(
                    package: package,
                    permit: preparation.permit
                )
                generatedPlaybackFile = playbackFile
                try requirePlaybackPreparation(preparation)
                try reauthenticateMessageDirection(
                    playableMessage,
                    expected: authenticatedDirection
                )

                if playableMessage.localThumbnailURL == nil {
                    generatedThumbnailURL = try? await mediaPipeline.makeThumbnail(
                        videoURL: playbackFile.url,
                        identifier: mediaIdentifiers.thumbnail,
                        permit: preparation.permit
                    )
                    try requirePlaybackPreparation(preparation)
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
                    try requirePlaybackPreparation(preparation)
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
                    try requirePlaybackPreparation(preparation)
                }

                // This is the final pin check after every suspension above. No
                // plaintext playback file, thumbnail, or delivery state is exposed
                // until the current contact still exactly matches the verified pin.
                try reauthenticateMessageDirection(
                    playableMessage,
                    expected: authenticatedDirection
                )
                try requirePlaybackPreparation(preparation)
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

    func markMessageWatched(messageID: UUID) async {
        guard let expectedAuthority = currentRefreshAuthority,
              let originalLocation = messageLocation(for: messageID),
              originalLocation.message.recipientID == expectedAuthority.userID,
              originalLocation.message.status == .delivered else {
            return
        }

        let response: Message
        do {
            response = try await apiClient.updateMessageStatus(
                messageID: messageID,
                status: .watched
            )
        } catch {
            // Watched receipts are best-effort metadata. Playback must remain
            // available offline, and a later playback start will retry.
            return
        }

        guard refreshAuthorityIsCurrent(expectedAuthority),
              response.id == messageID,
              response.senderID == originalLocation.message.senderID,
              response.recipientID == originalLocation.message.recipientID,
              response.status == .watched,
              let currentLocation = messageLocation(for: messageID),
              currentLocation.contactID == originalLocation.contactID,
              currentLocation.message.senderID == originalLocation.message.senderID,
              currentLocation.message.recipientID == expectedAuthority.userID,
              currentLocation.message.status == .delivered else {
            return
        }

        // Mutate the authenticated local record instead of publishing the
        // relay response, whose Codable form intentionally has no local URLs.
        // This preserves the encrypted package and thumbnail used by playback.
        var watchedMessage = currentLocation.message
        watchedMessage.status = .watched
        upsert(watchedMessage, contactID: currentLocation.contactID)
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
            // Delivery durability depends on the authenticated local
            // ciphertext and replay receipt, not on a best-effort local
            // thumbnail. Finish the network status transition first so no
            // post-thumbnail await can republish a stale plaintext URL.
            try await apiClient.acknowledgeDelivered(messageID: message.id)
            _ = try authenticateIncomingMessage(cachedMessage)
            cachedMessage.status = .delivered
            upsert(cachedMessage, contactID: contactID)

            try await makeAndPublishThumbnail(
                for: cachedMessage,
                localEncryptedPackageURL: package.localEncryptedCopyURL,
                direction: .incoming(playbackSecurity)
            ) { thumbnailURL in
                _ = try authenticateIncomingMessage(cachedMessage)
                var publishedMessage = cachedMessage
                publishedMessage.localThumbnailURL = thumbnailURL
                rememberLocalMedia(
                    for: publishedMessage,
                    encryptedIdentifier: mediaIdentifiers.encrypted,
                    thumbnailIdentifier: mediaIdentifiers.thumbnail
                )
                upsert(publishedMessage, contactID: contactID)
            }
        } catch {
            if let stagedReceivedPackage {
                await mediaPipeline.discardStagedReceivedPackage(stagedReceivedPackage)
            }
            // Keep the authenticated local copy visible; a later refresh can
            // regenerate a missing best-effort thumbnail.
        }
    }

    private func generateMissingThumbnails(for messages: [Message]) async {
        for message in messages.prefix(12) {
            guard message.localThumbnailURL == nil,
                  let localEncryptedPackageURL = message.localEncryptedPackageURL else {
                continue
            }

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
                try await makeAndPublishThumbnail(
                    for: message,
                    localEncryptedPackageURL: localEncryptedPackageURL,
                    direction: direction
                ) { thumbnailURL in
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
                }
            } catch {
                print("Kithra thumbnail generation failed for \(message.id.uuidString): \(error.localizedDescription)")
            }
        }
    }

    private func makeAndPublishThumbnail(
        for message: Message,
        localEncryptedPackageURL: URL,
        direction: AuthenticatedMessageDirection,
        publish: (URL) throws -> Void
    ) async throws {
        guard let preparation = beginPlaybackPreparation() else {
            throw MediaPipelineError.playbackPreparationInvalidated
        }
        defer { finishPlaybackPreparation(preparation.permit) }

        let mediaIdentifiers = try localMediaIdentifiers(
            for: message,
            direction: direction
        )
        let package = try playbackPackage(
            for: message,
            localEncryptedPackageURL: localEncryptedPackageURL,
            direction: direction
        )
        try requirePlaybackPreparation(preparation)
        try reauthenticateMessageDirection(message, expected: direction)
        let playbackFile = try await mediaPipeline.decryptForPlayback(
            package: package,
            permit: preparation.permit
        )
        var generatedThumbnailURL: URL?
        do {
            try requirePlaybackPreparation(preparation)
            try reauthenticateMessageDirection(message, expected: direction)
            let thumbnailURL = try await mediaPipeline.makeThumbnail(
                videoURL: playbackFile.url,
                identifier: mediaIdentifiers.thumbnail,
                permit: preparation.permit
            )
            generatedThumbnailURL = thumbnailURL
            try requirePlaybackPreparation(preparation)
            try reauthenticateMessageDirection(message, expected: direction)
            await mediaPipeline.cleanupTemporaryFiles([playbackFile.url])
            try requirePlaybackPreparation(preparation)
            try reauthenticateMessageDirection(message, expected: direction)
            // Publication is synchronous and occurs before the permit is
            // finished. Scene invalidation therefore either clears this URL
            // afterward or invalidates the permit before it can be published.
            try publish(thumbnailURL)
            generatedThumbnailURL = nil
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

    private func beginPlaybackPreparation() -> (
        generation: UInt64,
        permit: PlaybackPreparationPermit
    )? {
        guard allowsPlaybackPreparation else {
            return nil
        }
        let permit = PlaybackPreparationPermit()
        playbackPreparationPermits[permit.id] = permit
        return (playbackPreparationGeneration, permit)
    }

    private func requirePlaybackPreparation(
        _ preparation: (generation: UInt64, permit: PlaybackPreparationPermit)
    ) throws {
        guard allowsPlaybackPreparation,
              preparation.generation == playbackPreparationGeneration,
              playbackPreparationPermits[preparation.permit.id] === preparation.permit,
              preparation.permit.isValid else {
            throw MediaPipelineError.playbackPreparationInvalidated
        }
    }

    private func finishPlaybackPreparation(_ permit: PlaybackPreparationPermit) {
        if playbackPreparationPermits[permit.id] === permit {
            playbackPreparationPermits[permit.id] = nil
        }
    }

    private func beginPlaintextProduction(
        tracking urls: [URL]
    ) -> (generation: UInt64, permit: ForegroundPlaintextPermit)? {
        guard allowsPlaintextProduction else {
            return nil
        }
        let permit = ForegroundPlaintextPermit()
        do {
            try permit.registerOutputs(urls)
        } catch {
            return nil
        }
        plaintextProductionPermits[permit.id] = permit
        return (plaintextProductionGeneration, permit)
    }

    private func requirePlaintextProduction(
        _ preparation: (generation: UInt64, permit: ForegroundPlaintextPermit)
    ) throws {
        guard allowsPlaintextProduction,
              preparation.generation == plaintextProductionGeneration,
              plaintextProductionPermits[preparation.permit.id] === preparation.permit,
              preparation.permit.isValid else {
            throw MediaPipelineError.plaintextProductionInvalidated
        }
    }

    private func finishPlaintextProduction(_ permit: ForegroundPlaintextPermit) {
        if plaintextProductionPermits[permit.id] === permit {
            plaintextProductionPermits[permit.id] = nil
        }
    }

    private func clearLocalThumbnailReferencesForBackground() -> [URL] {
        var cleanupURLs = Array(localThumbnailURLs.values)
        var changed = false
        for contactID in Array(messagesByContactID.keys) {
            let messages = messagesByContactID[contactID, default: []]
            let clearedMessages = messages.map { message -> Message in
                guard let localThumbnailURL = message.localThumbnailURL else {
                    return message
                }
                cleanupURLs.append(localThumbnailURL)
                changed = true
                var clearedMessage = message
                clearedMessage.localThumbnailURL = nil
                return clearedMessage
            }
            messagesByContactID[contactID] = clearedMessages
        }
        localThumbnailURLs.removeAll()
        if changed {
            rebuildConversations()
        }
        return uniqueURLs(cleanupURLs)
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var paths: Set<String> = []
        return urls.compactMap { url in
            let canonicalURL = url.standardizedFileURL
            return paths.insert(canonicalURL.path).inserted ? canonicalURL : nil
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

    private func messageLocation(for messageID: UUID) -> (contactID: UUID, message: Message)? {
        for (contactID, messages) in messagesByContactID {
            if let message = messages.first(where: { $0.id == messageID }) {
                return (contactID, message)
            }
        }
        return nil
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
        } catch MediaPipelineError.playbackPreparationInvalidated {
            return false
        } catch MediaPipelineError.plaintextProductionInvalidated {
            return false
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    private func resumePendingAccountDeletion() async {
        needsAccountDeletionRetry = true
        suspendPublishedAuthenticationForAccountDeletion()
        _ = await perform {
            try await reconcilePendingAccountDeletion()
        }
        isRestoringSession = false
    }

    private func reconcilePendingAccountDeletion() async throws {
        guard let deletionIntent = pendingAccountDeletion else {
            needsAccountDeletionRetry = false
            return
        }
        mediaPipeline.closePlaintextProductionForAccountDeletion()
        try await removeInvalidatedPlaintextFiles()
        try await mediaPipeline.removeAbandonedPlaintextTemporaryFilesForAccountDeletion()
        if deletionIntent.phase == .relayDeletionConfirmed {
            try await clearLocalAccountState()
            return
        }
        guard let protectedSession = storedAuthSession
            ?? pendingRegistration?.storedSession else {
            throw AccountDeletionRecoveryError.missingProtectedSession
        }
        guard let relayURL = URL(string: deletionIntent.relayBaseURLString),
              RelayURLPolicy.allows(relayURL) else {
            throw AccountDeletionRecoveryError.invalidProtectedRelay
        }
        guard let identity = try await keyManager.currentIdentity() else {
            throw AccountDeletionRecoveryError.missingDeviceIdentity
        }
        try AuthSessionValidator.validateStoredRecoveryAuthority(
            protectedSession.session,
            requestedUsername: protectedSession.session.user.username,
            localIdentity: identity
        )
        try validateAccountDeletionIntent(
            deletionIntent,
            protectedSession: protectedSession,
            identity: identity
        )

        // A completed pending registration is also protected recovery
        // authority. Keep it in memory so the signed renewal path can replace
        // an expired bearer while this deletion is reconciled.
        storedAuthSession = protectedSession
        relayBaseURLString = relayURL.absoluteString
        await apiClient.updateBaseURL(relayURL)
        await apiClient.setAuthSession(protectedSession.session)

        do {
            switch try await apiClient.attemptAccountDeletion() {
            case .deleted:
                break
            case .unauthorized:
                let challenge: LoginChallenge
                do {
                    challenge = try await apiClient.requestLoginChallenge(
                        username: deletionIntent.username,
                        deviceID: deletionIntent.deviceID
                    )
                } catch let apiError as APIClientError
                    where apiError.isLoginIdentityNotFoundResponse {
                    // The relay challenge endpoint returns 401 only when this
                    // exact username/device identity no longer exists. This is
                    // the expected replay after a lost successful DELETE.
                    try confirmRelayAccountDeletion(deletionIntent)
                    try await clearLocalAccountState()
                    return
                }

                let renewedSession = try await performSessionRenewal(
                    challenge: challenge,
                    expectedAccountDeletionIntent: deletionIntent
                )
                await apiClient.setAuthSession(renewedSession)
                guard try await apiClient.attemptAccountDeletion() == .deleted else {
                    throw AccountDeletionRecoveryError.freshSessionRejected
                }
            }
        } catch {
            // Keep the persisted intent, session, signing key, and encrypted
            // media for an exact retry. No other protected request should reuse
            // this authority while deletion remains unresolved.
            await apiClient.setAuthSession(nil)
            needsAccountDeletionRetry = true
            throw error
        }

        try confirmRelayAccountDeletion(deletionIntent)
        try await clearLocalAccountState()
    }

    private func validateAccountDeletionIntent(
        _ record: PendingAccountDeletionRecord,
        protectedSession: StoredAuthSession,
        identity: DevicePublicIdentity
    ) throws {
        let session = protectedSession.session
        guard record.relayBaseURLString == protectedSession.relayBaseURLString,
              record.userID == session.user.id,
              record.username == session.user.username,
              record.deviceID == session.device.id,
              record.expectedIdentity.deviceID == identity.deviceID,
              record.expectedIdentity.encryptionPublicKey == identity.encryptionPublicKey,
              record.expectedIdentity.signingPublicKey == identity.signingPublicKey else {
            throw AccountDeletionRecoveryError.intentIdentityMismatch
        }
    }

    private func confirmRelayAccountDeletion(
        _ record: PendingAccountDeletionRecord
    ) throws {
        let confirmed = record.confirmingRelayDeletion()
        do {
            try AccountDeletionIntentPersistence.saveAndVerify(
                confirmed,
                in: accountDeletionIntentStore
            )
        } catch {
            isAccountDeletionIntentStorageUncertain = true
            needsAuthenticationStorageReload = true
            throw error
        }
        pendingAccountDeletion = confirmed
    }

    private func suspendPublishedAuthenticationForAccountDeletion() {
        accountStateGeneration &+= 1
        invalidatePlaintextProductionForBackground()
        registrationTask?.cancel()
        registrationTask = nil
        registrationAttemptID = nil
        registrationAttemptUsername = nil
        isRegistrationInFlight = false
        sessionRenewalTask?.cancel()
        sessionRenewalTask = nil
        stopRemotePolling()
        currentUser = nil
        deviceIdentity = nil
        contacts = []
        contactTrustAssessments = [:]
        conversations = []
        messagesByContactID = [:]
        lastInviteCode = nil
        activeIncomingReceiptOperations = []
    }

    private func clearLocalAccountState() async throws {
        isClearingLocalAccountState = true
        defer { isClearingLocalAccountState = false }
        // Persist the destructive intent before revoking any in-memory or
        // Keychain authority. A crash from this point onward must resume cleanup
        // instead of restoring a partially deleted account.
        bootstrapMarkers.beginCleanup()
        needsAccountDeletionRetry = pendingAccountDeletion != nil
        requiresFreshInstallKeychainReset = true
        accountStateGeneration &+= 1
        registrationTask?.cancel()
        registrationTask = nil
        registrationAttemptID = nil
        registrationAttemptUsername = nil
        isRegistrationInFlight = false
        sessionRenewalTask?.cancel()
        sessionRenewalTask = nil
        stopRemotePolling()
        playbackCleanupTask?.cancel()
        playbackCleanupTask = nil

        // Revoke all in-memory authority before the first cleanup suspension.
        // Otherwise a concurrent verification task can recreate a Keychain pin
        // after removeAll() and leave it behind when reset completes.
        storedAuthSession = nil
        pendingRegistration = nil
        needsAuthenticationStorageReload = false
        needsAuthenticationRecoveryRetry = false
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

        await apiClient.setAuthSession(nil)
        let failures = await cleanupAllLocalAccountStateWithRetries()
        // Keep RootView on the signed-in surface until all cleanup awaits finish;
        // otherwise SetupView can auto-create a replacement key while reset is
        // still deleting Keychain state.
        currentUser = nil

        if !failures.isEmpty {
            bootstrapMarkers.markCleanupFailed()
            needsLocalCleanupRetry = true
            throw LocalAccountCleanupError(failures: failures)
        }
        pendingAccountDeletion = nil
        needsAccountDeletionRetry = false
        isAccountDeletionIntentStorageUncertain = false
        bootstrapMarkers.discardLegacySession()
        bootstrapMarkers.completeCleanup()
        requiresFreshInstallKeychainReset = false
        needsLocalCleanupRetry = false
        mediaPipeline.reopenPlaintextProductionAfterAccountDeletionEnds()
    }

    private func clearResidualKeychainAfterFreshInstallIfNeeded() async throws {
        // A migration/readback or restore-validation failure is recoverable
        // state, not evidence of a reinstall. Do not create replacement keys
        // over it; require the user's explicit cleanup action first.
        guard !needsLocalCleanupRetry || requiresFreshInstallKeychainReset else {
            throw LocalAccountRecoveryRequiredError()
        }
        guard requiresFreshInstallKeychainReset else {
            return
        }

        // UserDefaults is removed by uninstall while Keychain items may remain.
        // Remove every app-owned session/identity/trust/replay namespace before
        // creating a fresh identity so old authority cannot silently reappear.
        bootstrapMarkers.beginCleanup()
        let failures = await cleanupAllLocalAccountStateWithRetries()
        guard failures.isEmpty else {
            bootstrapMarkers.markCleanupFailed()
            needsLocalCleanupRetry = true
            throw LocalAccountCleanupError(failures: failures)
        }
        bootstrapMarkers.discardLegacySession()
        bootstrapMarkers.completeCleanup()
        requiresFreshInstallKeychainReset = false
        needsLocalCleanupRetry = false
    }

    private func ensureAuthenticationBootstrapReadyForMutation() throws {
        guard !isAuthenticationBootstrapUncertain else {
            throw AuthenticationBootstrapBlockedError()
        }
    }

    private func loadProtectedAuthenticationRecords() throws -> (
        session: StoredAuthSession?,
        pending: PendingRegistrationRecord?,
        accountDeletion: PendingAccountDeletionRecord?
    ) {
        let accountDeletion: PendingAccountDeletionRecord?
        do {
            accountDeletion = try accountDeletionIntentStore.load()
            isAccountDeletionIntentStorageUncertain = false
            pendingAccountDeletion = accountDeletion
            needsAccountDeletionRetry = accountDeletion != nil
        } catch {
            isAccountDeletionIntentStorageUncertain = true
            throw error
        }
        let plan = bootstrapMarkers.plan(
            hasProtectedAccountDeletionIntent: accountDeletion != nil
        )
        if accountDeletion?.phase == .relayDeletionConfirmed {
            return (nil, nil, accountDeletion)
        }
        guard plan.permitsProtectedSessionRestore else {
            throw AuthenticationBootstrapBlockedError()
        }

        let session = try LocalAccountSessionBootstrap.loadOrMigrate(
            plan: plan,
            legacySessionData: bootstrapMarkers.legacySessionData,
            sessionStore: sessionStore,
            decodeLegacySession: Self.decodeLegacyPersistedSession
        ) { verifiedSession in
            bootstrapMarkers.preserveExistingInstallClassification()
            preferences.set(verifiedSession.relayBaseURLString, forKey: Self.relayBaseURLKey)
            bootstrapMarkers.discardLegacySession()
        }
        let pending = try pendingRegistrationStore.load()
        if let session,
           let pending,
           !PendingRegistrationRecovery.isCompatible(session, with: pending) {
            throw AuthSessionStoreError.conflictingRegistrationRecovery
        }
        if plan.requiresRegistrationReconciliation,
           session == nil,
           pending == nil {
            throw AuthSessionStoreError.ambiguousRegistrationRecovery
        }
        return (session, pending, accountDeletion)
    }

    private func restore(_ persistedSession: StoredAuthSession) async {
        defer { isRestoringSession = false }
        let restored = await perform {
            try await completeProtectedRegistration(
                persistedSession,
                requestedUsername: persistedSession.session.user.username,
                allowsExpiredRecoveryAuthority: true
            )
        }
        if restored {
            needsAuthenticationRecoveryRetry = false
        } else {
            await suspendPublishedAuthenticationForRetry()
        }
    }

    private func restorePendingRegistration(_ record: PendingRegistrationRecord) async {
        defer { isRestoringSession = false }
        let restored = await perform {
            try await completePendingRegistration(record)
        }
        if restored {
            needsAuthenticationRecoveryRetry = false
        } else {
            await suspendPublishedAuthenticationForRetry()
        }
    }

    private func renewSession() async throws -> AuthSession {
        guard pendingAccountDeletion == nil,
              !isAccountDeletionIntentStorageUncertain else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        if let sessionRenewalTask {
            return try await sessionRenewalTask.value
        }

        let task = Task { [weak self] () throws -> AuthSession in
            guard let self else {
                throw APIClientError.authenticationRecoveryUnavailable
            }
            return try await self.performSessionRenewal()
        }
        sessionRenewalTask = task
        do {
            let session = try await task.value
            sessionRenewalTask = nil
            return session
        } catch {
            sessionRenewalTask = nil
            throw error
        }
    }

    private func completeProtectedRegistration(
        _ protectedSession: StoredAuthSession,
        requestedUsername: String,
        allowsExpiredRecoveryAuthority: Bool = true,
        resolvesRegistrationUncertainty: Bool = true
    ) async throws {
        let registrationGeneration = accountStateGeneration
        guard let relayURL = URL(string: protectedSession.relayBaseURLString),
              RelayURLPolicy.allows(relayURL),
              relayURL.absoluteString == relayBaseURLString else {
#if DEBUG
            throw LocalAccountStateError.disallowedRelayURL(
                "The protected relay must use HTTPS or a local/private Debug HTTP address."
            )
#else
            throw LocalAccountStateError.disallowedRelayURL(
                "The protected relay uses HTTP. Public release builds require HTTPS."
            )
#endif
        }
        guard let identity = try await keyManager.currentIdentity() else {
            // A protected relay registration must only ever recover against
            // the exact keys that created it. Generating replacement keys here
            // would strand the relay account and weaken the recovery boundary.
            throw DeviceKeyManagerError.identityNotFound
        }
        guard accountStateGeneration == registrationGeneration,
              !isClearingLocalAccountState,
              storedAuthSession == protectedSession else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        if allowsExpiredRecoveryAuthority {
            try AuthSessionValidator.validateStoredRecoveryAuthority(
                protectedSession.session,
                requestedUsername: requestedUsername,
                localIdentity: identity
            )
        } else {
            try AuthSessionValidator.validateRegistration(
                protectedSession.session,
                requestedUsername: requestedUsername,
                localIdentity: identity
            )
        }
        await apiClient.updateBaseURL(relayURL)
        guard accountStateGeneration == registrationGeneration,
              !isClearingLocalAccountState,
              storedAuthSession == protectedSession else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        await apiClient.setAuthSession(protectedSession.session)
        guard accountStateGeneration == registrationGeneration,
              !isClearingLocalAccountState,
              storedAuthSession == protectedSession else {
            await apiClient.setAuthSession(nil)
            throw AuthSessionValidationError.noRecoverableSession
        }

        // Do not publish signed-in UI from a stale bearer alone. A successful
        // protected endpoint either authenticates that bearer or forces the API
        // client through the signed challenge-renewal path first.
        _ = try await apiClient.listContacts()
        guard accountStateGeneration == registrationGeneration,
              !isClearingLocalAccountState,
              let activeStoredSession = storedAuthSession,
              activeStoredSession.relayBaseURLString == protectedSession.relayBaseURLString,
              PendingRegistrationRecovery.isCompatible(
                activeStoredSession,
                with: PendingRegistrationRecord(
                    relayBaseURLString: protectedSession.relayBaseURLString,
                    username: requestedUsername,
                    session: protectedSession.session,
                    expectedIdentity: PendingRegistrationIdentity(identity)
                )
              ) else {
            await apiClient.setAuthSession(nil)
            throw AuthSessionValidationError.noRecoverableSession
        }

        let registeredIdentity: DevicePublicIdentity
        do {
            registeredIdentity = try await recoverRegisteredIdentity(
                identity,
                for: activeStoredSession.session,
                allowsExpiredRecoveryAuthority: true
            )
        } catch let validationError as AuthSessionValidationError {
            throw validationError
        } catch {
            throw RegistrationRecoveryError.bindingFailed(
                detail: error.localizedDescription
            )
        }
        guard accountStateGeneration == registrationGeneration,
              !isClearingLocalAccountState,
              storedAuthSession == activeStoredSession else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        try AuthSessionValidator.validateLocalIdentity(
            registeredIdentity,
            against: activeStoredSession.session
        )
        relayBaseURLString = relayURL.absoluteString
        preferences.set(relayURL.absoluteString, forKey: Self.relayBaseURLKey)
        currentUser = activeStoredSession.session.user
        deviceIdentity = registeredIdentity
        contacts = []
        conversations = []
        messagesByContactID = [:]
        try await refreshLocalState()
        if resolvesRegistrationUncertainty {
            bootstrapMarkers.resolveRegistrationUncertainty()
            needsAuthenticationStorageReload = false
        }
    }

    private func recoverRegisteredIdentity(
        _ identity: DevicePublicIdentity,
        for session: AuthSession,
        allowsExpiredRecoveryAuthority: Bool = false
    ) async throws -> DevicePublicIdentity {
        if allowsExpiredRecoveryAuthority {
            try AuthSessionValidator.validateStoredRecoveryAuthority(
                session,
                requestedUsername: session.user.username,
                localIdentity: identity
            )
        } else {
            try AuthSessionValidator.validateRegistration(
                session,
                requestedUsername: session.user.username,
                localIdentity: identity
            )
        }
        if identity.deviceID == nil {
            let boundIdentity = try await keyManager.bindRegisteredDeviceID(session.device.id)
            try AuthSessionValidator.validateLocalIdentity(boundIdentity, against: session)
            return boundIdentity
        }
        try AuthSessionValidator.validateLocalIdentity(identity, against: session)
        return identity
    }

    private func completePendingRegistration(
        _ record: PendingRegistrationRecord
    ) async throws {
        let registrationGeneration = accountStateGeneration
        guard pendingRegistration == record,
              !isClearingLocalAccountState,
              relayBaseURLString == record.relayBaseURLString else {
            throw AuthSessionValidationError.noRecoverableSession
        }

        // Always verify the exact intent again before any first or repeated
        // network request. This also protects records restored after relaunch.
        try PendingRegistrationPersistence.saveAndVerify(
            record,
            in: pendingRegistrationStore
        )
        guard accountStateGeneration == registrationGeneration,
              pendingRegistration == record,
              !isClearingLocalAccountState else {
            throw AuthSessionValidationError.noRecoverableSession
        }

        guard let identity = try await keyManager.currentIdentity() else {
            throw DeviceKeyManagerError.identityNotFound
        }
        try validatePendingRegistrationIdentity(record, against: identity)
        guard accountStateGeneration == registrationGeneration,
              pendingRegistration == record,
              !isClearingLocalAccountState else {
            throw AuthSessionValidationError.noRecoverableSession
        }

        var activeRecord = record
        if activeRecord.session == nil {
            bootstrapMarkers.markRegistrationUncertain()
            let session: AuthSession
            do {
                session = try await apiClient.register(
                    username: activeRecord.username,
                    deviceID: activeRecord.deviceID,
                    deviceName: activeRecord.deviceName,
                    encryptionPublicKey: identity.encryptionPublicKey,
                    signingPublicKey: identity.signingPublicKey
                )
            } catch let apiError as APIClientError
                where apiError.registrationWasDefinitelyNotAccepted {
                try abandonPendingRegistration(activeRecord)
                throw apiError
            } catch let conflictError as APIClientError
                where conflictError.registrationRequiresSignedRecovery {
                session = try await recoverRegistrationSessionAfterConflict(
                    conflictError,
                    record: activeRecord
                )
            } catch {
                throw error
            }
            guard accountStateGeneration == registrationGeneration,
                  pendingRegistration == activeRecord,
                  !isClearingLocalAccountState,
                  relayBaseURLString == activeRecord.relayBaseURLString,
                  let currentIdentity = try await keyManager.currentIdentity(),
                  currentIdentity == identity else {
                throw AuthSessionValidationError.noRecoverableSession
            }
            try AuthSessionValidator.validateRegistration(
                session,
                requestedUsername: activeRecord.username,
                localIdentity: currentIdentity
            )
            guard session.device.id == activeRecord.deviceID,
                  session.device.name == activeRecord.deviceName else {
                throw AuthSessionValidationError.identityMismatch
            }

            let completedRecord = activeRecord.completing(with: session)
            try PendingRegistrationPersistence.saveAndVerify(
                completedRecord,
                in: pendingRegistrationStore
            )
            guard accountStateGeneration == registrationGeneration,
                  pendingRegistration == activeRecord,
                  !isClearingLocalAccountState else {
                throw AuthSessionValidationError.noRecoverableSession
            }
            pendingRegistration = completedRecord
            activeRecord = completedRecord
        }

        let protectedSession: StoredAuthSession
        if let storedAuthSession {
            guard PendingRegistrationRecovery.isCompatible(
                storedAuthSession,
                with: activeRecord
            ) else {
                needsAuthenticationStorageReload = true
                needsAuthenticationRecoveryRetry = false
                throw AuthSessionStoreError.conflictingRegistrationRecovery
            }
            protectedSession = storedAuthSession
        } else {
            guard let pendingSession = activeRecord.storedSession else {
                throw AuthSessionValidationError.noRecoverableSession
            }
            protectedSession = pendingSession
            try ProtectedAuthSessionPersistence.saveAndVerify(
                protectedSession,
                in: sessionStore
            )
            storedAuthSession = protectedSession
        }

        try await completeProtectedRegistration(
            protectedSession,
            requestedUsername: activeRecord.username,
            allowsExpiredRecoveryAuthority: true,
            resolvesRegistrationUncertainty: false
        )
        guard accountStateGeneration == registrationGeneration,
              pendingRegistration == activeRecord,
              !isClearingLocalAccountState,
              let activeStoredSession = storedAuthSession,
              PendingRegistrationRecovery.isCompatible(activeStoredSession, with: activeRecord) else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        try PendingRegistrationPersistence.removeAndVerify(from: pendingRegistrationStore)
        pendingRegistration = nil
        bootstrapMarkers.resolveRegistrationUncertainty()
        needsAuthenticationStorageReload = false
    }

    private func recoverRegistrationSessionAfterConflict(
        _ conflictError: APIClientError,
        record: PendingRegistrationRecord
    ) async throws -> AuthSession {
        let challenge: LoginChallenge
        do {
            challenge = try await apiClient.requestLoginChallenge(
                username: record.username,
                deviceID: record.deviceID
            )
        } catch let challengeError as APIClientError
            where challengeError.isUnauthorizedResponse {
            // The single authoritative SQLite relay has neither this
            // username/device pair nor an account committed from our exact
            // request. The 409 was therefore a true username or device
            // conflict, so discarding the unused intent is safe and lets the
            // user choose another username. Network/5xx challenge failures and
            // every login failure remain fail-closed with the intent intact.
            try abandonPendingRegistration(record)
            throw conflictError
        }
        try AuthSessionValidator.validateChallenge(challenge)
        let challengeResponse = try await keyManager.makeLoginChallengeResponse(
            challenge: challenge.challenge
        )
        return try await apiClient.login(
            username: record.username,
            deviceID: record.deviceID,
            challengeID: challenge.challengeID,
            challengeResponse: challengeResponse
        )
    }

    private func abandonPendingRegistration(
        _ record: PendingRegistrationRecord
    ) throws {
        guard pendingRegistration == record,
              !isClearingLocalAccountState else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        try PendingRegistrationPersistence.removeAndVerify(
            from: pendingRegistrationStore
        )
        pendingRegistration = nil
        bootstrapMarkers.resolveRegistrationUncertainty()
    }

    private func validatePendingRegistrationIdentity(
        _ record: PendingRegistrationRecord,
        against identity: DevicePublicIdentity
    ) throws {
        guard identity.deviceID == nil || identity.deviceID == record.deviceID,
              record.expectedIdentity.deviceID == nil
                || record.expectedIdentity.deviceID == record.deviceID,
              identity.encryptionPublicKey == record.expectedIdentity.encryptionPublicKey,
              identity.signingPublicKey == record.expectedIdentity.signingPublicKey else {
            throw AuthSessionValidationError.identityMismatch
        }
        if let session = record.session {
            guard session.device.id == record.deviceID,
                  session.device.name == record.deviceName,
                  AuthSessionValidator.identitiesMatch(identity, session: session),
                  AuthSessionValidator.identitiesMatch(
                    record.expectedIdentity.publicIdentityForValidation,
                    session: session
                  ) else {
                throw AuthSessionValidationError.identityMismatch
            }
        }
    }

    private func suspendPublishedAuthenticationForRetry() async {
        needsAuthenticationRecoveryRetry = !needsAuthenticationStorageReload
            && (storedAuthSession != nil || pendingRegistration != nil)
        stopRemotePolling()
        currentUser = nil
        deviceIdentity = nil
        contacts = []
        contactTrustAssessments = [:]
        conversations = []
        messagesByContactID = [:]
        await apiClient.setAuthSession(nil)
    }

    private func recordAuthenticationRecoveryFailure(_ error: Error) {
        if let storeError = error as? AuthSessionStoreError,
           case .conflictingRegistrationRecovery = storeError {
            needsAuthenticationStorageReload = true
            needsAuthenticationRecoveryRetry = false
        } else {
            needsAuthenticationRecoveryRetry = true
        }
    }

    private func performSessionRenewal(
        challenge suppliedChallenge: LoginChallenge? = nil,
        expectedAccountDeletionIntent: PendingAccountDeletionRecord? = nil
    ) async throws -> AuthSession {
        guard sessionRenewalIsAllowed(
                  expectedAccountDeletionIntent: expectedAccountDeletionIntent
              ),
              !isClearingLocalAccountState,
              let previousStoredSession = storedAuthSession,
              let relayURL = URL(string: previousStoredSession.relayBaseURLString),
              RelayURLPolicy.allows(relayURL),
              relayURL.absoluteString == relayBaseURLString else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        let renewalGeneration = accountStateGeneration
        let identity: DevicePublicIdentity
        if let deviceIdentity {
            identity = deviceIdentity
        } else {
            guard let storedIdentity = try await keyManager.currentIdentity() else {
                throw DeviceKeyManagerError.identityNotFound
            }
            identity = storedIdentity
        }
        try Task.checkCancellation()
        guard sessionRenewalIsAllowed(
            expectedAccountDeletionIntent: expectedAccountDeletionIntent
        ) else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        try AuthSessionValidator.validateStoredRecoveryAuthority(
            previousStoredSession.session,
            requestedUsername: previousStoredSession.session.user.username,
            localIdentity: identity
        )
        let deviceID = previousStoredSession.session.device.id
        let username = previousStoredSession.session.user.username

        let challenge: LoginChallenge
        if let suppliedChallenge {
            challenge = suppliedChallenge
        } else {
            challenge = try await apiClient.requestLoginChallenge(
                username: username,
                deviceID: deviceID
            )
        }
        try Task.checkCancellation()
        guard sessionRenewalIsAllowed(
            expectedAccountDeletionIntent: expectedAccountDeletionIntent
        ) else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        try AuthSessionValidator.validateChallenge(challenge)
        let challengeResponse = try await keyManager.makeLoginChallengeResponse(
            challenge: challenge.challenge
        )
        let renewedSession = try await apiClient.login(
            username: username,
            deviceID: deviceID,
            challengeID: challenge.challengeID,
            challengeResponse: challengeResponse
        )
        try AuthSessionValidator.validateRenewal(
            renewedSession,
            replacing: previousStoredSession.session,
            localIdentity: identity,
            allowsUnboundLocalIdentity: true
        )
        try Task.checkCancellation()
        guard accountStateGeneration == renewalGeneration,
              sessionRenewalIsAllowed(
                  expectedAccountDeletionIntent: expectedAccountDeletionIntent
              ),
              !isClearingLocalAccountState,
              storedAuthSession == previousStoredSession else {
            throw AuthSessionValidationError.noRecoverableSession
        }

        let renewedStoredSession = StoredAuthSession(
            relayBaseURLString: previousStoredSession.relayBaseURLString,
            session: renewedSession
        )
        try ProtectedAuthSessionPersistence.saveAndVerify(
            renewedStoredSession,
            in: sessionStore
        )
        guard accountStateGeneration == renewalGeneration,
              sessionRenewalIsAllowed(
                  expectedAccountDeletionIntent: expectedAccountDeletionIntent
              ),
              !isClearingLocalAccountState,
              storedAuthSession == previousStoredSession else {
            throw AuthSessionValidationError.noRecoverableSession
        }
        storedAuthSession = renewedStoredSession
        return renewedSession
    }

    /// Generic protected requests must never mint or persist fresh authority
    /// once deletion is durable (or its Keychain state is unreadable). The
    /// only exception is the explicit deletion reconciler, bound to the exact
    /// pending record whose stale bearer just received 401.
    private func sessionRenewalIsAllowed(
        expectedAccountDeletionIntent: PendingAccountDeletionRecord?
    ) -> Bool {
        guard !isAccountDeletionIntentStorageUncertain else {
            return false
        }
        if let expectedAccountDeletionIntent {
            return expectedAccountDeletionIntent.phase == .awaitingRelayDeletion
                && pendingAccountDeletion == expectedAccountDeletionIntent
        }
        return pendingAccountDeletion == nil
    }

    private func cleanupProtectedAccountStateWithRetries() async -> [LocalCleanupFailure] {
        var failures: [LocalCleanupFailure] = []
        if let failure = await retryCleanup(
            label: "pending relay registration",
            operation: { try pendingRegistrationStore.remove() }
        ) {
            failures.append(failure)
        }
        if let failure = await retryCleanup(
            label: "protected relay session",
            operation: { try sessionStore.remove() }
        ) {
            failures.append(failure)
        }
        if let failure = await retryCleanup(
            label: "contact verification pins",
            operation: { try contactTrustStore.removeAll() }
        ) {
            failures.append(failure)
        }
        if let failure = await retryCleanup(
            label: "message replay receipts",
            operation: { try await messageReplayStore.removeAll() }
        ) {
            failures.append(failure)
        }
        if let failure = await retryCleanup(
            label: "device identity",
            operation: { try await keyManager.removeIdentity() }
        ) {
            failures.append(failure)
        }
        return failures
    }

    private func cleanupAllLocalAccountStateWithRetries() async -> [LocalCleanupFailure] {
        var failures = await cleanupProtectedAccountStateWithRetries()
        if let mediaFailure = await retryCleanup(
            label: "encrypted local media",
            operation: { try await mediaPipeline.removeAllLocalMedia() }
        ) {
            failures.append(mediaFailure)
        }
        // A capture/export callback may finish after the pre-DELETE sweep.
        // Scan the direct app temporary root again before removing the
        // confirmed intent; an active or undeletable plaintext file keeps the
        // crash-durable cleanup authority for a local-only retry.
        if failures.isEmpty,
           pendingAccountDeletion != nil,
           let plaintextFailure = await retryCleanup(
               label: "plaintext temporary media",
               operation: {
                   try await mediaPipeline
                       .removeAbandonedPlaintextTemporaryFilesForAccountDeletion()
               }
           ) {
            failures.append(plaintextFailure)
        }
        // Keep the crash-durable deletion phase until every other protected
        // namespace and local media directory is gone. If cleanup is partial,
        // a reinstall can still see the confirmed record and resume safely.
        if failures.isEmpty,
           let deletionFailure = await retryCleanup(
               label: "protected account-deletion intent",
               operation: {
                   try AccountDeletionIntentPersistence.removeAndVerify(
                       from: accountDeletionIntentStore
                   )
               }
           ) {
            failures.append(deletionFailure)
        }
        return failures
    }

    private func retryCleanup(
        label: String,
        attempts: Int = 3,
        operation: () async throws -> Void
    ) async -> LocalCleanupFailure? {
        var latestError: Error?
        for attempt in 1...attempts {
            do {
                try await operation()
                return nil
            } catch {
                latestError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 100_000_000)
                }
            }
        }
        return LocalCleanupFailure(
            label: label,
            detail: latestError?.localizedDescription ?? "unknown failure"
        )
    }

    private func persistRelayBaseURLString() {
        preferences.set(relayBaseURLString, forKey: Self.relayBaseURLKey)
    }

    private static func decodeLegacyPersistedSession(_ data: Data) throws -> StoredAuthSession {
        let legacySession = try sessionDecoder.decode(LegacyPersistedAuthSession.self, from: data)
        return StoredAuthSession(
            relayBaseURLString: legacySession.relayBaseURLString,
            session: legacySession.session
        )
    }

    private static var bundledDefaultRelayURL: URL {
        let fallback: URL
#if DEBUG
        fallback = localDefaultRelayURL
#else
        fallback = publicDefaultRelayURL
#endif
        guard let value = Bundle.main.object(forInfoDictionaryKey: "KithraDefaultRelayURL") as? String else {
            return fallback
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$("),
              let url = URL(string: trimmed),
              RelayURLPolicy.allows(url) else {
            return fallback
        }
        return url
    }

    private static let sessionDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct LegacyPersistedAuthSession: Codable, Hashable {
    var relayBaseURLString: String
    var session: AuthSession
}

private struct LocalCleanupFailure: Hashable {
    var label: String
    var detail: String
}

private struct LocalAccountCleanupError: Error, LocalizedError {
    var failures: [LocalCleanupFailure]

    var errorDescription: String? {
        let details = failures.map { "\($0.label): \($0.detail)" }.joined(separator: "; ")
        return "Local account cleanup is incomplete. Retry before creating new keys. \(details)"
    }
}

private struct LocalAccountRecoveryRequiredError: Error, LocalizedError {
    var errorDescription: String? {
        "Protected account recovery is incomplete. Retry local cleanup before creating replacement device keys."
    }
}

private enum AccountDeletionRecoveryError: Error, LocalizedError {
    case missingProtectedSession
    case missingDeviceIdentity
    case invalidProtectedRelay
    case intentIdentityMismatch
    case freshSessionRejected

    var errorDescription: String? {
        switch self {
        case .missingProtectedSession:
            return "Account deletion is pending, but its protected relay session is unavailable. Kithra kept the deletion record and local keys for retry."
        case .missingDeviceIdentity:
            return "Account deletion is pending, but its protected device identity is unavailable. Kithra kept the deletion record for recovery."
        case .invalidProtectedRelay:
            return "Account deletion is pending for an invalid protected relay URL. Kithra did not send or erase anything."
        case .intentIdentityMismatch:
            return "The protected deletion record does not match this relay account and device. Kithra refused to delete the relay account or local keys."
        case .freshSessionRejected:
            return "The relay rejected account deletion immediately after signed session recovery. Kithra kept the protected deletion record and local keys for retry."
        }
    }
}

enum LocalRegistrationResetConfirmation: Equatable {
    case eraseProtectedLocalAccount
}

private struct AuthenticationBootstrapBlockedError: Error, LocalizedError {
    var errorDescription: String? {
        "Protected authentication storage or account recovery is not yet reconciled. Reload protected storage or retry recovery before changing the relay, creating keys, or registering."
    }
}

private enum RegistrationRecoveryError: Error, LocalizedError {
    case usernameMismatch(expected: String)
    case bindingFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .usernameMismatch(let expected):
            return "Finish recovering the protected registration for \(expected) before using another username."
        case .bindingFailed(let detail):
            return "The relay registration is protected in Keychain, but Kithra could not finish binding this device (\(detail)). Retry Register with the same username or relaunch Kithra."
        }
    }
}

private struct DefinitiveUploadLocalCleanupError: Error, LocalizedError {
    var uploadDetail: String
    var cleanupDetail: String

    var errorDescription: String? {
        "\(uploadDetail) Kithra could not remove the rejected local sender copy: \(cleanupDetail). Retry local cleanup before sending it again."
    }
}

private struct MediaSendPlaintextCleanupError: Error, LocalizedError {
    var sendDetail: String
    var cleanupDetail: String

    var errorDescription: String? {
        "\(sendDetail) Plaintext cleanup also failed: \(cleanupDetail)"
    }
}

private enum LocalAccountStateError: Error, LocalizedError {
    case disallowedRelayURL(String)

    var errorDescription: String? {
        switch self {
        case .disallowedRelayURL(let message):
            return message
        }
    }
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
