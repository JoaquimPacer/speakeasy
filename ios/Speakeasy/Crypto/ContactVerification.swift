import Darwin
import Foundation
import Sodium

enum ContactVerificationError: Error, LocalizedError {
    case invalidRelayURL
    case unsupportedRelayScheme
    case invalidUsername
    case missingLocalDeviceID
    case invalidEncryptionPublicKey
    case invalidSigningPublicKey
    case mismatchedRelay
    case identicalIdentities
    case hashingFailed
    case malformedIdentity
    case unsupportedIdentityVersion(Int)
    case malformedQRCode
    case unsupportedQRCodeVersion(Int)
    case invalidQRCodeSignature
    case unexpectedPresenter
    case safetyNumberMismatch

    var errorDescription: String? {
        switch self {
        case .invalidRelayURL:
            return "The relay URL does not contain a valid origin."
        case .unsupportedRelayScheme:
            return "Contact verification requires an HTTP or HTTPS relay URL."
        case .invalidUsername:
            return "The account username cannot be represented in a safety number."
        case .missingLocalDeviceID:
            return "The local device must be registered before contacts can be verified."
        case .invalidEncryptionPublicKey:
            return "The device encryption public key must contain exactly 32 bytes."
        case .invalidSigningPublicKey:
            return "The device signing public key must contain exactly 32 bytes."
        case .mismatchedRelay:
            return "Both devices must use the same relay origin."
        case .identicalIdentities:
            return "A device cannot verify its own identity as a contact."
        case .hashingFailed:
            return "libsodium could not calculate the contact fingerprint."
        case .malformedIdentity:
            return "The contact identity bundle is malformed."
        case .unsupportedIdentityVersion(let version):
            return "Contact identity version \(version) is not supported."
        case .malformedQRCode:
            return "The contact verification QR code is malformed."
        case .unsupportedQRCodeVersion(let version):
            return "Contact verification QR version \(version) is not supported."
        case .invalidQRCodeSignature:
            return "The contact verification QR signature is invalid."
        case .unexpectedPresenter:
            return "The scanned identity does not match this contact."
        case .safetyNumberMismatch:
            return "The scanned safety number does not match this device."
        }
    }
}

/// The immutable, relay-scoped public identity used for out-of-band contact verification.
///
/// Both local and remote devices use the same representation. Including both public keys
/// prevents a relay from substituting either the media-encryption key or the authentication
/// signing key without invalidating the safety number.
struct ContactVerificationIdentity: Codable, Hashable {
    static let currentVersion = 1
    static let publicKeyByteCount = 32

    let formatVersion: Int
    let relayOrigin: String
    let relayScopeHash: Data
    let userID: UUID
    let username: String
    let deviceID: UUID
    let encryptionPublicKey: Data
    let signingPublicKey: Data

    init(
        relayURL: URL,
        userID: UUID,
        username: String,
        deviceID: UUID,
        encryptionPublicKey: Data,
        signingPublicKey: Data
    ) throws {
        let relayOrigin = try RelayOrigin.normalized(url: relayURL)
        try self.init(
            canonicalRelayOrigin: relayOrigin,
            suppliedRelayScopeHash: nil,
            userID: userID,
            username: username,
            deviceID: deviceID,
            encryptionPublicKey: encryptionPublicKey,
            signingPublicKey: signingPublicKey
        )
    }

    init(relayURL: URL, user: SpeakeasyUser, device: DevicePublicIdentity) throws {
        guard let deviceID = device.deviceID else {
            throw ContactVerificationError.missingLocalDeviceID
        }

        try self.init(
            relayURL: relayURL,
            userID: user.id,
            username: user.username,
            deviceID: deviceID,
            encryptionPublicKey: device.encryptionPublicKey,
            signingPublicKey: device.signingPublicKey
        )
    }

    init(relayURL: URL, contact: Contact) throws {
        try self.init(
            relayURL: relayURL,
            userID: contact.contactID,
            username: contact.username,
            deviceID: contact.deviceID,
            encryptionPublicKey: contact.encryptionPublicKey,
            signingPublicKey: contact.signingPublicKey
        )
    }

    /// Returns the relay-scope digest after reducing the URL to its canonical
    /// origin. Trust-record removal uses this without constructing a complete
    /// contact identity from relay-controlled names or public keys.
    static func canonicalRelayScopeHash(for relayURL: URL) throws -> Data {
        try canonicalRelayScopeHash(
            forCanonicalRelayOrigin: RelayOrigin.normalized(url: relayURL)
        )
    }

    func constantTimeEquals(_ other: ContactVerificationIdentity) -> Bool {
        VerificationCrypto.constantTimeEquals(canonicalBytes, other.canonicalBytes)
    }

    /// Stable per-device digest for binding authenticated protocol messages to this
    /// complete relay-scoped identity. This is distinct from both `relayScopeHash`
    /// and the symmetric two-party safety-number digest.
    var identityDigest: Data {
        get throws {
            try VerificationCrypto.hash(
                domain: ContactVerificationFormat.identityDigestDomain,
                fields: [canonicalBytes]
            )
        }
    }

    var canonicalBytes: Data {
        var output = Data(ContactVerificationFormat.identityDomain.utf8)
        output.appendUInt8(UInt8(Self.currentVersion))
        output.appendLengthPrefixedUTF8(relayOrigin)
        output.append(relayScopeHash)
        output.append(contentsOf: userID.uuidString.lowercased().utf8)
        output.appendLengthPrefixedUTF8(username)
        output.append(contentsOf: deviceID.uuidString.lowercased().utf8)
        output.append(encryptionPublicKey)
        output.append(signingPublicKey)
        return output
    }

    static func parseCanonical(_ data: Data) throws -> ContactVerificationIdentity {
        var reader = VerificationBinaryReader(data: data)
        let domain = try reader.read(count: ContactVerificationFormat.identityDomain.utf8.count)
        guard domain == Data(ContactVerificationFormat.identityDomain.utf8) else {
            throw ContactVerificationError.malformedIdentity
        }

        let version = Int(try reader.readUInt8())
        guard version == currentVersion else {
            throw ContactVerificationError.unsupportedIdentityVersion(version)
        }

        let relayOrigin = try reader.readLengthPrefixedUTF8(
            maximumByteCount: RelayOrigin.maximumOriginByteCount
        )
        let suppliedRelayScopeHash = try reader.read(count: VerificationCrypto.digestByteCount)
        let userID = try reader.readCanonicalUUID()
        let username = try reader.readLengthPrefixedUTF8(maximumByteCount: maximumUsernameByteCount)
        let deviceID = try reader.readCanonicalUUID()
        let encryptionPublicKey = try reader.read(count: publicKeyByteCount)
        let signingPublicKey = try reader.read(count: publicKeyByteCount)

        guard reader.isAtEnd else {
            throw ContactVerificationError.malformedIdentity
        }

        let identity = try ContactVerificationIdentity(
            canonicalRelayOrigin: relayOrigin,
            suppliedRelayScopeHash: suppliedRelayScopeHash,
            userID: userID,
            username: username,
            deviceID: deviceID,
            encryptionPublicKey: encryptionPublicKey,
            signingPublicKey: signingPublicKey
        )

        guard VerificationCrypto.constantTimeEquals(identity.canonicalBytes, data) else {
            throw ContactVerificationError.malformedIdentity
        }
        return identity
    }

    private static let maximumUsernameByteCount = 128

    private init(
        canonicalRelayOrigin: String,
        suppliedRelayScopeHash: Data?,
        userID: UUID,
        username: String,
        deviceID: UUID,
        encryptionPublicKey: Data,
        signingPublicKey: Data
    ) throws {
        guard let relayURL = URL(string: canonicalRelayOrigin),
              try RelayOrigin.normalized(url: relayURL) == canonicalRelayOrigin else {
            throw ContactVerificationError.invalidRelayURL
        }

        let normalizedUsername = username.precomposedStringWithCanonicalMapping
        let usernameBytes = Data(normalizedUsername.utf8)
        guard !normalizedUsername.isEmpty,
              usernameBytes.count <= Self.maximumUsernameByteCount,
              !normalizedUsername.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ContactVerificationError.invalidUsername
        }
        guard encryptionPublicKey.count == Self.publicKeyByteCount else {
            throw ContactVerificationError.invalidEncryptionPublicKey
        }
        guard signingPublicKey.count == Self.publicKeyByteCount else {
            throw ContactVerificationError.invalidSigningPublicKey
        }

        let calculatedRelayScopeHash = try Self.canonicalRelayScopeHash(
            forCanonicalRelayOrigin: canonicalRelayOrigin
        )
        if let suppliedRelayScopeHash,
           !VerificationCrypto.constantTimeEquals(suppliedRelayScopeHash, calculatedRelayScopeHash) {
            throw ContactVerificationError.malformedIdentity
        }

        self.formatVersion = Self.currentVersion
        self.relayOrigin = canonicalRelayOrigin
        self.relayScopeHash = calculatedRelayScopeHash
        self.userID = userID
        self.username = normalizedUsername
        self.deviceID = deviceID
        self.encryptionPublicKey = encryptionPublicKey
        self.signingPublicKey = signingPublicKey
    }

    private static func canonicalRelayScopeHash(
        forCanonicalRelayOrigin relayOrigin: String
    ) throws -> Data {
        try VerificationCrypto.hash(
            domain: ContactVerificationFormat.relayScopeDomain,
            fields: [Data(relayOrigin.utf8)]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case relayOrigin
        case relayScopeHash
        case userID
        case username
        case deviceID
        case encryptionPublicKey
        case signingPublicKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard version == Self.currentVersion else {
            throw ContactVerificationError.unsupportedIdentityVersion(version)
        }

        try self.init(
            canonicalRelayOrigin: container.decode(String.self, forKey: .relayOrigin),
            suppliedRelayScopeHash: container.decode(Data.self, forKey: .relayScopeHash),
            userID: container.decode(UUID.self, forKey: .userID),
            username: container.decode(String.self, forKey: .username),
            deviceID: container.decode(UUID.self, forKey: .deviceID),
            encryptionPublicKey: container.decode(Data.self, forKey: .encryptionPublicKey),
            signingPublicKey: container.decode(Data.self, forKey: .signingPublicKey)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(relayOrigin, forKey: .relayOrigin)
        try container.encode(relayScopeHash, forKey: .relayScopeHash)
        try container.encode(userID, forKey: .userID)
        try container.encode(username, forKey: .username)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(encryptionPublicKey, forKey: .encryptionPublicKey)
        try container.encode(signingPublicKey, forKey: .signingPublicKey)
    }
}

struct ContactVerificationContext: Hashable {
    let localIdentity: ContactVerificationIdentity
    let remoteIdentity: ContactVerificationIdentity

    init(
        relayURL: URL,
        localUser: SpeakeasyUser,
        localDeviceIdentity: DevicePublicIdentity,
        contact: Contact
    ) throws {
        guard contact.userID == localUser.id else {
            throw ContactVerificationError.unexpectedPresenter
        }

        self.localIdentity = try ContactVerificationIdentity(
            relayURL: relayURL,
            user: localUser,
            device: localDeviceIdentity
        )
        self.remoteIdentity = try ContactVerificationIdentity(relayURL: relayURL, contact: contact)
    }

    var safetyNumber: ContactSafetyNumber {
        get throws {
            try ContactSafetyNumber(localIdentity, remoteIdentity)
        }
    }
}

/// A symmetric BLAKE2b-256 digest rendered as the complete 60-digit safety code.
struct ContactSafetyNumber: Hashable {
    static let digitCount = 60
    static let displayGroupSize = 5

    let digest: Data
    let digits: String

    init(_ firstIdentity: ContactVerificationIdentity, _ secondIdentity: ContactVerificationIdentity) throws {
        guard VerificationCrypto.constantTimeEquals(
            firstIdentity.relayScopeHash,
            secondIdentity.relayScopeHash
        ) else {
            throw ContactVerificationError.mismatchedRelay
        }
        guard !firstIdentity.constantTimeEquals(secondIdentity) else {
            throw ContactVerificationError.identicalIdentities
        }

        let first = firstIdentity.canonicalBytes
        let second = secondIdentity.canonicalBytes
        let orderedFields = first.lexicographicallyPrecedes(second)
            ? [first, second]
            : [second, first]
        let digest = try VerificationCrypto.hash(
            domain: ContactVerificationFormat.safetyNumberDomain,
            fields: orderedFields
        )

        self.digest = digest
        self.digits = Self.decimalCode(from: digest)
    }

    var formattedDigits: String {
        stride(from: 0, to: digits.count, by: Self.displayGroupSize).map { start in
            let startIndex = digits.index(digits.startIndex, offsetBy: start)
            let endIndex = digits.index(
                startIndex,
                offsetBy: min(Self.displayGroupSize, digits.count - start)
            )
            return String(digits[startIndex..<endIndex])
        }.joined(separator: " ")
    }

    func constantTimeMatches(digest otherDigest: Data) -> Bool {
        VerificationCrypto.constantTimeEquals(digest, otherDigest)
    }

    private static func decimalCode(from digest: Data) -> String {
        // Repeated division returns the least-significant 60 decimal digits of the
        // complete 256-bit digest and left-pads the full displayed code with zeroes.
        var working = Array(digest)
        defer { VerificationCrypto.wipe(&working) }
        var reversedDigits = [UInt8]()
        reversedDigits.reserveCapacity(digitCount)

        for _ in 0..<digitCount {
            var remainder = 0
            for index in working.indices {
                let value = remainder * 256 + Int(working[index])
                working[index] = UInt8(value / 10)
                remainder = value % 10
            }
            reversedDigits.append(UInt8(remainder))
        }

        return reversedDigits.reversed().map(String.init).joined()
    }
}

/// Signed, peer-specific data encoded in a contact-verification QR image.
///
/// The pair digest ties the presenter's identity to the intended scanner. The detached
/// Ed25519 signature proves that the device displaying the QR owns the signing key that
/// appears in the identity bundle.
struct ContactVerificationQRPayload: Hashable {
    static let currentVersion = 1
    static let textPrefix = "KITHRA:VERIFY:1:"

    let formatVersion: Int
    let presenterIdentity: ContactVerificationIdentity
    let pairDigest: Data
    let signature: Data

    init(
        presenterIdentity: ContactVerificationIdentity,
        expectedPeerIdentity: ContactVerificationIdentity,
        signature: Data
    ) throws {
        let safetyNumber = try ContactSafetyNumber(presenterIdentity, expectedPeerIdentity)
        try self.init(
            presenterIdentity: presenterIdentity,
            pairDigest: safetyNumber.digest,
            signature: signature
        )
    }

    static func signingBytes(
        presenterIdentity: ContactVerificationIdentity,
        expectedPeerIdentity: ContactVerificationIdentity
    ) throws -> Data {
        let safetyNumber = try ContactSafetyNumber(presenterIdentity, expectedPeerIdentity)
        return unsignedBytes(
            presenterIdentity: presenterIdentity,
            pairDigest: safetyNumber.digest
        )
    }

    var encodedString: String {
        let encoded = rawBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.textPrefix + encoded
    }

    static func parse(_ encodedString: String) throws -> ContactVerificationQRPayload {
        guard encodedString.hasPrefix(textPrefix), encodedString.count <= maximumEncodedCharacterCount else {
            throw ContactVerificationError.malformedQRCode
        }

        let encoded = String(encodedString.dropFirst(textPrefix.count))
        guard !encoded.isEmpty,
              encoded.utf8.allSatisfy({
                  ($0 >= 65 && $0 <= 90) ||
                  ($0 >= 97 && $0 <= 122) ||
                  ($0 >= 48 && $0 <= 57) ||
                  $0 == 45 || $0 == 95
              }),
              encoded.count % 4 != 1 else {
            throw ContactVerificationError.malformedQRCode
        }

        let paddingCount = (4 - encoded.count % 4) % 4
        let padded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: paddingCount)
        guard let rawData = Data(base64Encoded: padded),
              canonicalBase64URL(rawData) == encoded else {
            throw ContactVerificationError.malformedQRCode
        }

        var rawBytes = Array(rawData)
        defer { VerificationCrypto.wipe(&rawBytes) }
        var reader = VerificationBinaryReader(data: Data(rawBytes))
        let domain = try reader.read(count: ContactVerificationFormat.qrDomain.utf8.count)
        guard domain == Data(ContactVerificationFormat.qrDomain.utf8) else {
            throw ContactVerificationError.malformedQRCode
        }

        let version = Int(try reader.readUInt8())
        guard version == currentVersion else {
            throw ContactVerificationError.unsupportedQRCodeVersion(version)
        }

        let identityLength = Int(try reader.readUInt16())
        guard identityLength > 0,
              identityLength <= ContactVerificationFormat.maximumCanonicalIdentityByteCount else {
            throw ContactVerificationError.malformedQRCode
        }
        let identity = try ContactVerificationIdentity.parseCanonical(
            reader.read(count: identityLength)
        )
        let pairDigest = try reader.read(count: VerificationCrypto.digestByteCount)
        let signature = try reader.read(count: VerificationCrypto.signatureByteCount)
        guard reader.isAtEnd else {
            throw ContactVerificationError.malformedQRCode
        }

        return try ContactVerificationQRPayload(
            presenterIdentity: identity,
            pairDigest: pairDigest,
            signature: signature
        )
    }

    func validate(
        scannedBy localIdentity: ContactVerificationIdentity,
        expectedPresenter: ContactVerificationIdentity
    ) throws -> ContactSafetyNumber {
        guard presenterIdentity.constantTimeEquals(expectedPresenter) else {
            throw ContactVerificationError.unexpectedPresenter
        }

        let safetyNumber = try ContactSafetyNumber(localIdentity, expectedPresenter)
        guard safetyNumber.constantTimeMatches(digest: pairDigest) else {
            throw ContactVerificationError.safetyNumberMismatch
        }
        return safetyNumber
    }

    private static let maximumEncodedCharacterCount = 2_048

    private init(
        presenterIdentity: ContactVerificationIdentity,
        pairDigest: Data,
        signature: Data
    ) throws {
        guard pairDigest.count == VerificationCrypto.digestByteCount,
              signature.count == VerificationCrypto.signatureByteCount else {
            throw ContactVerificationError.malformedQRCode
        }

        let unsigned = Self.unsignedBytes(
            presenterIdentity: presenterIdentity,
            pairDigest: pairDigest
        )
        guard VerificationCrypto.verifySignature(
            signature,
            message: unsigned,
            publicKey: presenterIdentity.signingPublicKey
        ) else {
            throw ContactVerificationError.invalidQRCodeSignature
        }

        self.formatVersion = Self.currentVersion
        self.presenterIdentity = presenterIdentity
        self.pairDigest = pairDigest
        self.signature = signature
    }

    private static func unsignedBytes(
        presenterIdentity: ContactVerificationIdentity,
        pairDigest: Data
    ) -> Data {
        var output = Data(ContactVerificationFormat.qrDomain.utf8)
        output.appendUInt8(UInt8(currentVersion))
        output.appendUInt16(UInt16(presenterIdentity.canonicalBytes.count))
        output.append(presenterIdentity.canonicalBytes)
        output.append(pairDigest)
        return output
    }

    private var rawBytes: Data {
        var output = Self.unsignedBytes(
            presenterIdentity: presenterIdentity,
            pairDigest: pairDigest
        )
        output.append(signature)
        return output
    }

    private static func canonicalBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum ContactVerificationFormat {
    static let relayScopeDomain = "KITHRA/RELAY-SCOPE/V1\u{0}"
    static let identityDomain = "KITHRA/CONTACT-IDENTITY/V1\u{0}"
    static let identityDigestDomain = "KITHRA/CONTACT-IDENTITY-DIGEST/V1\u{0}"
    static let safetyNumberDomain = "KITHRA/SAFETY-NUMBER/V1\u{0}"
    static let qrDomain = "KITHRA/CONTACT-VERIFY-QR/V1\u{0}"
    static let maximumCanonicalIdentityByteCount = 1_024
}

private enum RelayOrigin {
    static let maximumOriginByteCount = 512

    static func normalized(url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              components.user == nil,
              components.password == nil else {
            throw ContactVerificationError.invalidRelayURL
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw ContactVerificationError.unsupportedRelayScheme
        }

        let host = try normalizedHost(rawHost)

        let port = components.port
        if let port, !(1...65_535).contains(port) {
            throw ContactVerificationError.invalidRelayURL
        }
        let shouldIncludePort = port != nil && !(
            (scheme == "https" && port == 443) ||
            (scheme == "http" && port == 80)
        )
        let normalized = scheme + "://" + host + (shouldIncludePort ? ":\(port!)" : "")
        guard !normalized.utf8.isEmpty,
              normalized.utf8.count <= maximumOriginByteCount else {
            throw ContactVerificationError.invalidRelayURL
        }
        return normalized
    }

    private static func normalizedHost(_ rawHost: String) throws -> String {
        var candidate = rawHost.precomposedStringWithCanonicalMapping.lowercased()
        if candidate.hasPrefix("[") || candidate.hasSuffix("]") {
            guard candidate.hasPrefix("["), candidate.hasSuffix("]") else {
                throw ContactVerificationError.invalidRelayURL
            }
            candidate = String(candidate.dropFirst().dropLast())
        }
        guard !candidate.isEmpty, !candidate.contains("%") else {
            // Scoped IPv6 literals are deliberately excluded from portable pins.
            throw ContactVerificationError.invalidRelayURL
        }

        if candidate.contains(":") {
            var address = in6_addr()
            guard candidate.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                throw ContactVerificationError.invalidRelayURL
            }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &output, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                throw ContactVerificationError.invalidRelayURL
            }
            return "[\(String(cString: output))]"
        }

        var ipv4Address = in_addr()
        if candidate.withCString({ inet_pton(AF_INET, $0, &ipv4Address) }) == 1 {
            var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4Address, &output, socklen_t(INET_ADDRSTRLEN)) != nil else {
                throw ContactVerificationError.invalidRelayURL
            }
            return String(cString: output)
        }

        if candidate.hasSuffix(".") {
            candidate.removeLast()
        }
        let asciiScalars = candidate.unicodeScalars
        guard !candidate.isEmpty,
              asciiScalars.allSatisfy({ scalar in
                  scalar.isASCII &&
                      ((scalar.value >= 97 && scalar.value <= 122) ||
                       (scalar.value >= 48 && scalar.value <= 57) ||
                       scalar.value == 45 || scalar.value == 46)
              }),
              !candidate.allSatisfy({ $0.isNumber || $0 == "." }) else {
            throw ContactVerificationError.invalidRelayURL
        }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard candidate.utf8.count <= 253,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 &&
                      label.first != "-" && label.last != "-"
              }) else {
            throw ContactVerificationError.invalidRelayURL
        }
        return candidate
    }
}

private enum VerificationCrypto {
    static let digestByteCount = 32
    static let signatureByteCount = 64
    private static let sodium = Sodium()

    static func hash(domain: String, fields: [Data]) throws -> Data {
        var message = Data(domain.utf8)
        for field in fields {
            message.appendUInt32(UInt32(field.count))
            message.append(field)
        }
        guard let digest = sodium.genericHash.hash(
            message: Array(message),
            outputLength: digestByteCount
        ) else {
            throw ContactVerificationError.hashingFailed
        }
        return Data(digest)
    }

    static func constantTimeEquals(_ first: Data, _ second: Data) -> Bool {
        sodium.utils.equals(Array(first), Array(second))
    }

    static func verifySignature(_ signature: Data, message: Data, publicKey: Data) -> Bool {
        guard signature.count == signatureByteCount else {
            return false
        }
        return sodium.sign.verify(
            message: Array(message),
            publicKey: Array(publicKey),
            signature: Array(signature)
        )
    }

    static func wipe(_ bytes: inout [UInt8]) {
        sodium.utils.zero(&bytes)
    }
}

private struct VerificationBinaryReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw ContactVerificationError.malformedQRCode
        }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    mutating func readUInt8() throws -> UInt8 {
        guard let byte = try read(count: 1).first else {
            throw ContactVerificationError.malformedQRCode
        }
        return byte
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try read(count: 2)
        return (UInt16(bytes[bytes.startIndex]) << 8) |
            UInt16(bytes[bytes.index(after: bytes.startIndex)])
    }

    mutating func readLengthPrefixedUTF8(maximumByteCount: Int) throws -> String {
        let byteCount = Int(try readUInt16())
        guard byteCount > 0, byteCount <= maximumByteCount else {
            throw ContactVerificationError.malformedIdentity
        }
        let bytes = try read(count: byteCount)
        guard let value = String(data: bytes, encoding: .utf8),
              Data(value.utf8) == bytes else {
            throw ContactVerificationError.malformedIdentity
        }
        return value
    }

    mutating func readCanonicalUUID() throws -> UUID {
        let bytes = try read(count: 36)
        guard let string = String(data: bytes, encoding: .utf8),
              let uuid = UUID(uuidString: string),
              uuid.uuidString.lowercased() == string else {
            throw ContactVerificationError.malformedIdentity
        }
        return uuid
    }
}

private extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendLengthPrefixedUTF8(_ value: String) {
        let bytes = Data(value.utf8)
        precondition(bytes.count <= Int(UInt16.max))
        appendUInt16(UInt16(bytes.count))
        append(bytes)
    }
}
