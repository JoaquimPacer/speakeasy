import Foundation

struct APIConfiguration: Hashable {
    var baseURL: URL
    var bearerToken: String? = nil
    var sessionExpiresAt: Date? = nil
}

enum APIClientError: Error, LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case serverStatus(Int, Data)
    case missingAuthToken
    case authenticationRecoveryUnavailable
    case uploadNotAttempted(String)
    case definitiveUploadRejection(Int, Data)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The relay base URL is invalid."
        case .invalidResponse:
            return "The relay returned a non-HTTP response."
        case .serverStatus(let statusCode, let data):
            let serverMessage = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let serverMessage, !serverMessage.isEmpty {
                return "The relay returned HTTP \(statusCode): \(serverMessage)"
            }
            return "The relay returned HTTP \(statusCode)."
        case .missingAuthToken:
            return "This endpoint requires an authenticated session."
        case .authenticationRecoveryUnavailable:
            return "The relay session expired and could not be renewed safely."
        case .uploadNotAttempted(let detail):
            return "The encrypted video was not uploaded: \(detail)"
        case .definitiveUploadRejection(let statusCode, let data):
            let serverMessage = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch statusCode {
            case 413:
                return "The relay rejected this encrypted video because it is too large. Record a shorter video or choose 480p."
            case 507:
                if let serverMessage, !serverMessage.isEmpty {
                    return "The relay has no pending-message capacity right now: \(serverMessage)"
                }
                return "The relay has no pending-message capacity right now. Retry after pending videos are delivered or expire."
            default:
                return "The relay definitively rejected this upload with HTTP \(statusCode)."
            }
        }
    }

    var uploadWasDefinitelyNotAccepted: Bool {
        switch self {
        case .uploadNotAttempted, .definitiveUploadRejection:
            return true
        default:
            return false
        }
    }

    /// Malformed registration input is rejected before a request can commit.
    /// Conflicts require signed recovery because the same device may already
    /// exist after a lost response.
    var registrationWasDefinitelyNotAccepted: Bool {
        guard case .serverStatus(let statusCode, _) = self else {
            return false
        }
        return statusCode == 400
    }

    var registrationRequiresSignedRecovery: Bool {
        guard case .serverStatus(let statusCode, _) = self else {
            return false
        }
        return statusCode == 409
    }

    var isUnauthorizedResponse: Bool {
        guard case .serverStatus(let statusCode, _) = self else {
            return false
        }
        return statusCode == 401
    }
}

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

actor SpeakeasyAPIClient {
    typealias AuthenticationRecoveryHandler = @Sendable () async throws -> AuthSession

    private var configuration: APIConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var authenticationRecoveryHandler: AuthenticationRecoveryHandler?
    private let proactiveRenewalWindow: TimeInterval = 60

    init(configuration: APIConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func updateConfiguration(_ configuration: APIConfiguration) {
        self.configuration = configuration
    }

    func updateBaseURL(_ baseURL: URL) {
        configuration.baseURL = baseURL
    }

    func setBearerToken(_ token: String?) {
        configuration.bearerToken = token
        if token == nil {
            configuration.sessionExpiresAt = nil
        }
    }

    func setAuthSession(_ session: AuthSession?) {
        configuration.bearerToken = session?.bearerToken
        configuration.sessionExpiresAt = session?.expiresAt
    }

    func setAuthenticationRecoveryHandler(_ handler: AuthenticationRecoveryHandler?) {
        authenticationRecoveryHandler = handler
    }

    func register(
        username: String,
        deviceID: UUID,
        deviceName: String?,
        encryptionPublicKey: Data,
        signingPublicKey: Data
    ) async throws -> AuthSession {
        let payload = RegisterRequest(
            username: username,
            deviceID: deviceID,
            deviceName: deviceName,
            encryptionPublicKey: encryptionPublicKey,
            signingPublicKey: signingPublicKey
        )
        return try await send(path: "/auth/register", method: .post, body: payload, requiresAuth: false)
    }

    func requestLoginChallenge(username: String, deviceID: UUID) async throws -> LoginChallenge {
        let payload = LoginChallengeRequest(username: username, deviceID: deviceID)
        return try await send(path: "/auth/challenge", method: .post, body: payload, requiresAuth: false)
    }

    func login(
        username: String,
        deviceID: UUID,
        challengeID: UUID,
        challengeResponse: Data
    ) async throws -> AuthSession {
        let payload = LoginRequest(
            username: username,
            deviceID: deviceID,
            challengeID: challengeID,
            challengeResponse: challengeResponse
        )
        return try await send(path: "/auth/login", method: .post, body: payload, requiresAuth: false)
    }

    func logout() async throws {
        let _: EmptyResponse = try await send(
            path: "/auth/logout",
            method: .post,
            body: EmptyResponse(),
            requiresAuth: true
        )
    }

    func registerDevice(name: String?, encryptionPublicKey: Data, signingPublicKey: Data) async throws -> SpeakeasyDevice {
        let payload = RegisterDeviceRequest(
            name: name,
            encryptionPublicKey: encryptionPublicKey,
            signingPublicKey: signingPublicKey
        )
        return try await send(path: "/auth/device", method: .post, body: payload, requiresAuth: true)
    }

    func createContactInvite() async throws -> ContactInvite {
        let payload = CreateContactInviteRequest()
        return try await send(path: "/contacts/invite", method: .post, body: payload, requiresAuth: true)
    }

    func acceptContactInvite(code: String) async throws -> Contact {
        let payload = AcceptContactInviteRequest(code: code)
        return try await send(path: "/contacts/accept", method: .post, body: payload, requiresAuth: true)
    }

    func listContacts() async throws -> [Contact] {
        try await send(path: "/contacts", method: .get, requiresAuth: true)
    }

    func deleteContact(contactID: UUID) async throws {
        let _: EmptyResponse = try await send(
            path: "/contacts/\(contactID.uuidString)",
            method: .delete,
            requiresAuth: true
        )
    }

    func blockContact(contactID: UUID) async throws {
        let payload = BlockContactRequest(blockedUserID: contactID)
        let _: EmptyResponse = try await send(
            path: "/blocks",
            method: .post,
            body: payload,
            requiresAuth: true
        )
    }

    func reportContact(contactID: UUID, reason: String, details: String = "") async throws {
        let payload = ReportContactRequest(
            reportedUserID: contactID,
            messageID: nil,
            reason: reason,
            details: details
        )
        let _: EmptyResponse = try await send(
            path: "/reports",
            method: .post,
            body: payload,
            requiresAuth: true
        )
    }

    func listMessages() async throws -> [Message] {
        let (data, response) = try await data(
            for: { try self.makeRequest(path: "/messages", method: .get, requiresAuth: true) },
            requiresAuth: true
        )
        try validate(response: response, data: data)
        return try decodeLossyArray(Message.self, from: data)
    }

    func uploadMessage(
        recipientID: UUID,
        recipientDeviceID: UUID,
        envelope: MessageEnvelope,
        encryptedBlobFileURL: URL,
        blobSize: Int
    ) async throws -> Message {
        try EncryptedMediaUploadPolicy.validate(
            fileURL: encryptedBlobFileURL,
            declaredBlobSize: blobSize
        )
        let metadata = UploadMessageMetadata(
            recipientID: recipientID,
            recipientDeviceID: recipientDeviceID,
            envelope: envelope,
            blobSize: blobSize
        )

        return try await uploadMultipart(
            path: "/messages",
            metadata: metadata,
            encryptedBlobFileURL: encryptedBlobFileURL
        )
    }

    func downloadMessage(id: UUID) async throws -> URL {
        let (temporaryURL, response) = try await download(
            for: {
                var request = try self.makeRequest(
                    path: "/messages/\(id.uuidString)",
                    method: .get,
                    requiresAuth: true
                )
                request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
                return request
            },
            requiresAuth: true
        )
        try validate(response: response, data: Data())
        return temporaryURL
    }

    func acknowledgeDelivered(messageID: UUID) async throws {
        let _: EmptyResponse = try await send(
            path: "/messages/\(messageID.uuidString)/delivered",
            method: .post,
            body: EmptyResponse(),
            requiresAuth: true
        )
    }

    func updateMessageStatus(messageID: UUID, status: MessageStatus) async throws -> Message {
        let payload = UpdateMessageStatusRequest(status: status)
        return try await send(
            path: "/messages/\(messageID.uuidString)/status",
            method: .patch,
            body: payload,
            requiresAuth: true
        )
    }

    func deleteMessage(messageID: UUID) async throws {
        let _: EmptyResponse = try await send(
            path: "/messages/\(messageID.uuidString)",
            method: .delete,
            requiresAuth: true
        )
    }

    func deleteAccount() async throws {
        let _: EmptyResponse = try await send(
            path: "/account",
            method: .delete,
            requiresAuth: true
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: HTTPMethod,
        requiresAuth: Bool
    ) async throws -> Response {
        let (data, response) = try await data(
            for: { try self.makeRequest(path: path, method: method, requiresAuth: requiresAuth) },
            requiresAuth: requiresAuth
        )
        try validate(response: response, data: data)
        return try decode(Response.self, from: data)
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: HTTPMethod,
        body: Body,
        requiresAuth: Bool
    ) async throws -> Response {
        let encodedBody = try encoder.encode(body)
        let (data, response) = try await data(
            for: {
                var request = try self.makeRequest(path: path, method: method, requiresAuth: requiresAuth)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = encodedBody
                return request
            },
            requiresAuth: requiresAuth
        )
        try validate(response: response, data: data)
        return try decode(Response.self, from: data)
    }

    private func uploadMultipart<Response: Decodable, Metadata: Encodable>(
        path: String,
        metadata: Metadata,
        encryptedBlobFileURL: URL
    ) async throws -> Response {
        let boundary = "speakeasy-\(UUID().uuidString)"
        let multipartFile: MultipartUploadFile
        do {
            multipartFile = try MultipartUploadFileBuilder.build(
                metadataData: encoder.encode(metadata),
                encryptedBlobFileURL: encryptedBlobFileURL,
                boundary: boundary
            )
        } catch {
            throw APIClientError.uploadNotAttempted(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: multipartFile.url) }

        let (data, response) = try await upload(
            for: {
                var request = try self.makeRequest(path: path, method: .post, requiresAuth: true)
                request.setValue(
                    "multipart/form-data; boundary=\(boundary)",
                    forHTTPHeaderField: "Content-Type"
                )
                request.setValue(
                    String(multipartFile.contentLength),
                    forHTTPHeaderField: "Content-Length"
                )
                return request
            },
            fromFile: multipartFile.url,
            requiresAuth: true
        )
        if let statusCode = (response as? HTTPURLResponse)?.statusCode,
           statusCode == 413 || statusCode == 507 {
            throw APIClientError.definitiveUploadRejection(statusCode, data)
        }
        try validate(response: response, data: data)
        return try decode(Response.self, from: data)
    }

    private func data(
        for makeRequest: () throws -> URLRequest,
        requiresAuth: Bool
    ) async throws -> (Data, URLResponse) {
        if requiresAuth {
            try await prepareAuthenticatedRequestIfNeeded()
        }
        let request = try makeRequest()
        let attemptedToken = configuration.bearerToken
        var result = try await session.data(for: request)

        if requiresAuth, isUnauthorized(result.1) {
            try await recoverAfterUnauthorized(attemptedToken: attemptedToken)
            let retryRequest = try makeRequest()
            let retryToken = configuration.bearerToken
            result = try await session.data(for: retryRequest)
            clearRejectedTokenIfNeeded(response: result.1, attemptedToken: retryToken)
        }
        return result
    }

    private func download(
        for makeRequest: () throws -> URLRequest,
        requiresAuth: Bool
    ) async throws -> (URL, URLResponse) {
        if requiresAuth {
            try await prepareAuthenticatedRequestIfNeeded()
        }
        let request = try makeRequest()
        let attemptedToken = configuration.bearerToken
        var result = try await session.download(for: request)

        if requiresAuth, isUnauthorized(result.1) {
            try await recoverAfterUnauthorized(attemptedToken: attemptedToken)
            let retryRequest = try makeRequest()
            let retryToken = configuration.bearerToken
            result = try await session.download(for: retryRequest)
            clearRejectedTokenIfNeeded(response: result.1, attemptedToken: retryToken)
        }
        return result
    }

    private func upload(
        for makeRequest: () throws -> URLRequest,
        fromFile bodyFileURL: URL,
        requiresAuth: Bool
    ) async throws -> (Data, URLResponse) {
        if requiresAuth {
            do {
                try await prepareAuthenticatedRequestIfNeeded()
            } catch {
                throw APIClientError.uploadNotAttempted(error.localizedDescription)
            }
        }
        let request: URLRequest
        do {
            request = try makeRequest()
        } catch {
            throw APIClientError.uploadNotAttempted(error.localizedDescription)
        }
        let attemptedToken = configuration.bearerToken
        var result = try await session.upload(for: request, fromFile: bodyFileURL)

        if requiresAuth, isUnauthorized(result.1) {
            do {
                try await recoverAfterUnauthorized(attemptedToken: attemptedToken)
            } catch {
                throw APIClientError.uploadNotAttempted(error.localizedDescription)
            }
            let retryRequest: URLRequest
            do {
                retryRequest = try makeRequest()
            } catch {
                throw APIClientError.uploadNotAttempted(error.localizedDescription)
            }
            let retryToken = configuration.bearerToken
            result = try await session.upload(for: retryRequest, fromFile: bodyFileURL)
            clearRejectedTokenIfNeeded(response: result.1, attemptedToken: retryToken)
        }
        return result
    }

    private func prepareAuthenticatedRequestIfNeeded() async throws {
        if configuration.bearerToken == nil {
            try await recoverAuthentication()
            return
        }
        if let expiresAt = configuration.sessionExpiresAt,
           expiresAt <= Date().addingTimeInterval(proactiveRenewalWindow) {
            try await recoverAuthentication()
        }
    }

    private func recoverAfterUnauthorized(attemptedToken: String?) async throws {
        // Another actor-reentrant request may already have renewed while this
        // request was in flight. Reuse that authority instead of minting a
        // second session and potentially invalidating the first one.
        if let currentToken = configuration.bearerToken,
           currentToken != attemptedToken,
           configuration.sessionExpiresAt.map({ $0 > Date() }) ?? true {
            return
        }
        do {
            try await recoverAuthentication()
        } catch {
            if configuration.bearerToken == attemptedToken {
                configuration.bearerToken = nil
                configuration.sessionExpiresAt = nil
            }
            throw error
        }
    }

    private func recoverAuthentication() async throws {
        guard let authenticationRecoveryHandler else {
            throw APIClientError.authenticationRecoveryUnavailable
        }
        let recoveredSession = try await authenticationRecoveryHandler()
        guard !recoveredSession.bearerToken.isEmpty,
              let expiresAt = recoveredSession.expiresAt,
              expiresAt > Date() else {
            throw AuthSessionValidationError.missingOrExpiredSession
        }
        configuration.bearerToken = recoveredSession.bearerToken
        configuration.sessionExpiresAt = expiresAt
    }

    private func isUnauthorized(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse)?.statusCode == 401
    }

    private func clearRejectedTokenIfNeeded(response: URLResponse, attemptedToken: String?) {
        guard isUnauthorized(response), configuration.bearerToken == attemptedToken else {
            return
        }
        configuration.bearerToken = nil
        configuration.sessionExpiresAt = nil
    }

    private func makeRequest(path: String, method: HTTPMethod, requiresAuth: Bool) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw APIClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if requiresAuth {
            guard let token = configuration.bearerToken else {
                throw APIClientError.missingAuthToken
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIClientError.serverStatus(httpResponse.statusCode, data)
        }
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }

        return try decoder.decode(type, from: data)
    }

    private func decodeLossyArray<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> [Value] {
        try decoder.decode([LossyDecodable<Value>].self, from: data).compactMap(\.value)
    }
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct RegisterRequest: Encodable {
    var username: String
    var deviceID: UUID
    var deviceName: String?
    var encryptionPublicKey: Data
    var signingPublicKey: Data
}

private struct LoginRequest: Encodable {
    var username: String
    var deviceID: UUID
    var challengeID: UUID
    var challengeResponse: Data
}

private struct LoginChallengeRequest: Encodable {
    var username: String
    var deviceID: UUID
}

private struct RegisterDeviceRequest: Encodable {
    var name: String?
    var encryptionPublicKey: Data
    var signingPublicKey: Data
}

private struct CreateContactInviteRequest: Encodable {}

private struct AcceptContactInviteRequest: Encodable {
    var code: String
}

private struct BlockContactRequest: Encodable {
    var blockedUserID: UUID
}

private struct ReportContactRequest: Encodable {
    var reportedUserID: UUID
    var messageID: UUID?
    var reason: String
    var details: String
}

private struct UploadMessageMetadata: Encodable {
    var recipientID: UUID
    var recipientDeviceID: UUID
    var envelope: MessageEnvelope
    var blobSize: Int
}

private struct UpdateMessageStatusRequest: Encodable {
    var status: MessageStatus
}

struct MultipartUploadFile: Equatable {
    let url: URL
    let contentLength: Int64
}

enum MultipartUploadFileError: Error, LocalizedError {
    case invalidChunkSize
    case cannotCreateTemporaryBody

    var errorDescription: String? {
        switch self {
        case .invalidChunkSize:
            return "The upload buffer size is invalid."
        case .cannotCreateTemporaryBody:
            return "Kithra could not create a protected temporary upload body."
        }
    }
}

enum MultipartUploadFileBuilder {
    static func build(
        metadataData: Data,
        encryptedBlobFileURL: URL,
        boundary: String,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        chunkSize: Int = 1 << 20
    ) throws -> MultipartUploadFile {
        guard chunkSize > 0 else {
            throw MultipartUploadFileError.invalidChunkSize
        }

        let directory = temporaryDirectory ?? fileManager.temporaryDirectory
            .appendingPathComponent("KithraMultipartUploads", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var mutableDirectory = directory
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(directoryValues)

        let outputURL = directory
            .appendingPathComponent("upload-\(UUID().uuidString)")
            .appendingPathExtension("multipart")
        guard fileManager.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw MultipartUploadFileError.cannotCreateTemporaryBody
        }

        do {
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: encryptedBlobFileURL)
            defer { try? input.close() }

            var prefix = Data()
            prefix.appendUTF8("--\(boundary)\r\n")
            prefix.appendUTF8("Content-Disposition: form-data; name=\"metadata\"\r\n")
            prefix.appendUTF8("Content-Type: application/json\r\n\r\n")
            prefix.append(metadataData)
            prefix.appendUTF8("\r\n")
            prefix.appendUTF8("--\(boundary)\r\n")
            prefix.appendUTF8("Content-Disposition: form-data; name=\"blob\"; filename=\"encrypted-video.blob\"\r\n")
            prefix.appendUTF8("Content-Type: application/octet-stream\r\n\r\n")
            try output.write(contentsOf: prefix)

            var contentLength = Int64(prefix.count)
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                contentLength += Int64(chunk.count)
            }

            let suffix = Data("\r\n--\(boundary)--\r\n".utf8)
            try output.write(contentsOf: suffix)
            contentLength += Int64(suffix.count)
            try output.synchronize()

            return MultipartUploadFile(url: outputURL, contentLength: contentLength)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
