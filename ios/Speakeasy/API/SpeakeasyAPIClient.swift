import Foundation

struct APIConfiguration: Hashable {
    var baseURL: URL
    var bearerToken: String?
}

enum APIClientError: Error, LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case serverStatus(Int, Data)
    case missingAuthToken

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The relay base URL is invalid."
        case .invalidResponse:
            return "The relay returned a non-HTTP response."
        case .serverStatus(let statusCode, _):
            return "The relay returned HTTP \(statusCode)."
        case .missingAuthToken:
            return "This endpoint requires an authenticated session."
        }
    }
}

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

actor SpeakeasyAPIClient {
    private var configuration: APIConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
    }

    func register(username: String, deviceName: String?, encryptionPublicKey: Data, signingPublicKey: Data) async throws -> AuthSession {
        let payload = RegisterRequest(
            username: username,
            deviceName: deviceName,
            encryptionPublicKey: encryptionPublicKey,
            signingPublicKey: signingPublicKey
        )
        return try await send(path: "/auth/register", method: .post, body: payload, requiresAuth: false)
    }

    func login(username: String, deviceID: UUID, challengeResponse: Data) async throws -> AuthSession {
        let payload = LoginRequest(username: username, deviceID: deviceID, challengeResponse: challengeResponse)
        return try await send(path: "/auth/login", method: .post, body: payload, requiresAuth: false)
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

    func listMessages() async throws -> [Message] {
        try await send(path: "/messages", method: .get, requiresAuth: true)
    }

    func uploadMessage(
        recipientID: UUID,
        envelope: MessageEnvelope,
        encryptedBlobFileURL: URL,
        blobSize: Int
    ) async throws -> Message {
        let metadata = UploadMessageMetadata(
            recipientID: recipientID,
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
        var request = try makeRequest(path: "/messages/\(id.uuidString)", method: .get, requiresAuth: true)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let (temporaryURL, response) = try await session.download(for: request)
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

    private func send<Response: Decodable>(
        path: String,
        method: HTTPMethod,
        requiresAuth: Bool
    ) async throws -> Response {
        let request = try makeRequest(path: path, method: method, requiresAuth: requiresAuth)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decode(Response.self, from: data)
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: HTTPMethod,
        body: Body,
        requiresAuth: Bool
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: method, requiresAuth: requiresAuth)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decode(Response.self, from: data)
    }

    private func uploadMultipart<Response: Decodable, Metadata: Encodable>(
        path: String,
        metadata: Metadata,
        encryptedBlobFileURL: URL
    ) async throws -> Response {
        let boundary = "speakeasy-\(UUID().uuidString)"
        var request = try makeRequest(path: path, method: .post, requiresAuth: true)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        try body.appendMultipartJSONPart(
            name: "metadata",
            filename: "metadata.json",
            value: metadata,
            encoder: encoder,
            boundary: boundary
        )
        body.appendMultipartFilePart(
            name: "blob",
            filename: encryptedBlobFileURL.lastPathComponent,
            contentType: "application/octet-stream",
            fileData: try Data(contentsOf: encryptedBlobFileURL),
            boundary: boundary
        )
        body.appendString("--\(boundary)--\r\n")

        let (data, response) = try await session.upload(for: request, from: body)
        try validate(response: response, data: data)
        return try decode(Response.self, from: data)
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
}

private struct RegisterRequest: Encodable {
    var username: String
    var deviceName: String?
    var encryptionPublicKey: Data
    var signingPublicKey: Data
}

private struct LoginRequest: Encodable {
    var username: String
    var deviceID: UUID
    var challengeResponse: Data
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

private struct UploadMessageMetadata: Encodable {
    var recipientID: UUID
    var envelope: MessageEnvelope
    var blobSize: Int
}

private struct UpdateMessageStatusRequest: Encodable {
    var status: MessageStatus
}

private extension Data {
    mutating func appendMultipartJSONPart<T: Encodable>(
        name: String,
        filename: String,
        value: T,
        encoder: JSONEncoder,
        boundary: String
    ) throws {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: application/json\r\n\r\n")
        append(try encoder.encode(value))
        appendString("\r\n")
    }

    mutating func appendMultipartFilePart(
        name: String,
        filename: String,
        contentType: String,
        fileData: Data,
        boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(contentType)\r\n\r\n")
        append(fileData)
        appendString("\r\n")
    }

    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
