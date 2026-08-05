# Kithra Identity Verification v1

## Purpose and scope

Identity Verification v1 lets two people authenticate the device keys they use
for a one-to-one Kithra conversation without trusting the relay to distribute
those keys honestly. The users compare a safety number or scan a signed QR code
over an independent channel, then each client pins the verified identities
locally.

This protocol authenticates one Kithra device for each user on one normalized
relay origin. It does not hide metadata, make the relay available, recover lost
keys, authenticate a person's civil identity, or provide Signal-style forward
secrecy. A QR code sent through the same possibly compromised Kithra conversation
is not an independent verification channel.

V1 supports one active device per user. Reinstalling the app, changing either
device key, changing the username, changing the device or user ID, moving to a
different relay origin, or adding a replacement device requires verification
again. Multi-device trust and signed key rotation are future protocol work.

On iOS, Keychain items can outlive an app uninstall while the app's UserDefaults
install marker does not. On a first launch with no persisted session or install
marker, Kithra deletes residual device-identity, contact-pin, and replay-receipt
Keychain namespaces before generating a new device identity. This deliberately
makes prior contacts appear unverified after reinstall. If session restoration
fails because protected keys and relay identity no longer agree, Setup exposes a
local-identity reset instead of silently reusing the bound identity for a new
registration.

## Primitive encoding

All byte strings below are written in network order. Implementations must not
hash JSON, a localized display string, a Swift `UUID` memory layout, or a Go
struct serialization.

- `raw(s)` is the exact byte sequence `s` and has no prefix.
- `u16be(n)` and `u32be(n)` are unsigned, fixed-width big-endian integers.
- `lp16(b)` is `u16be(len(b)) || b`.
- `lp32(b)` is `u32be(len(b)) || b`.
- Length is measured in bytes, not Unicode scalar values or characters.
- String values are UTF-8 without a byte-order mark.
- UUID values in the identity bundle are the lowercase, hyphenated 36-byte
  ASCII representation (`8-4-4-4-12`). Parse and re-encode the UUID; do not
  merely lowercase an arbitrary string.
- Public keys are raw 32-byte keys, not PEM, DER, hexadecimal, or base64 text.
- `BLAKE2b-256(m)` is unkeyed BLAKE2b with a 32-byte output, as provided by
  libsodium `crypto_generichash`.
- Comparisons of digests and canonical identities obtained from another device
  must be constant-time.

Every domain below includes its terminal NUL byte. Domain strings are raw and
are not themselves length-prefixed.

## Normalized relay origin

The relay origin is part of every identity so verification cannot be silently
carried from one self-hosted relay to another. Reduce the configured relay URL
to one origin string before hashing:

1. Parse an absolute URL and reject user information.
2. Accept only `http` or `https` and lowercase the scheme. Public builds require
   `https`; `http` exists only for local development.
3. Canonicalize IPv4 and unscoped IPv6 literals with `inet_pton`/`inet_ntop`
   (RFC 3986 brackets around IPv6). For DNS names, require lowercase ASCII
   A-labels, remove one trailing dot, and enforce DNS label lengths. Reject
   Unicode host text, numeric strings that are not canonical IPv4, empty labels,
   zone-scoped IPv6, whitespace, controls, and invalid label punctuation.
4. Omit port 443 for `https` and port 80 for `http`. Otherwise append the parsed
   port in decimal; valid ports are 1 through 65535.
5. Exclude path, query, and fragment. The result is
   `scheme://host[:port]`, with no trailing slash.

For example, `https://RELAY.Example.Test:443/` becomes
`https://relay.example.test`.

Cross-platform clients must produce exactly the same parsed host. Relay
operators must configure an ASCII DNS A-label for internationalized names; V1
does not define an IDNA mapping from Unicode display names.

The relay scope hash is:

```text
relayScopeInput = raw("KITHRA/RELAY-SCOPE/V1\0")
               || lp32(normalizedRelayOrigin UTF-8)
relayScopeHash = BLAKE2b-256(relayScopeInput)
```

## Canonical contact identity

Normalize the relay-stored username to Unicode NFC. Do not case-fold or trim it
while hashing. A V1 username must be nonempty, at most 128 UTF-8 bytes, and
contain no Unicode control characters.

The canonical identity is:

```text
raw("KITHRA/CONTACT-IDENTITY/V1\0")
|| 0x01
|| lp16(normalizedRelayOrigin UTF-8)
|| relayScopeHash[32]
|| userID lowercase canonical UUID ASCII[36]
|| lp16(username NFC UTF-8)
|| deviceID lowercase canonical UUID ASCII[36]
|| X25519 encryption public key[32]
|| Ed25519 signing public key[32]
```

The parser rejects unknown versions, noncanonical UUIDs, malformed UTF-8,
wrong-sized keys, a relay-scope hash that does not recompute, and trailing data.

The per-device identity digest used by Message Envelope v2 is:

```text
identityDigestInput = raw("KITHRA/CONTACT-IDENTITY-DIGEST/V1\0")
                    || lp32(canonicalIdentity)
identityDigest = BLAKE2b-256(identityDigestInput)
```

Clients construct their own identity from the authenticated user/device IDs,
the session username, and public keys derived from local private keys. If the
relay's copy of the current device keys differs from locally derived keys, the
account is in a local-identity-mismatch condition and verification and messaging
must stop.

## Pair digest and safety number

Let `a` and `b` be the complete canonical identity byte strings. Sort them in
unsigned lexicographic byte order so both devices obtain the same result:

```text
low, high = sortLexicographically(a, b)
safetyInput = raw("KITHRA/SAFETY-NUMBER/V1\0")
            || lp32(low)
            || lp32(high)
pairDigest = BLAKE2b-256(safetyInput)
```

Both identities must contain the same `relayScopeHash`, and a device cannot pair
with an identical canonical identity.

The printable safety number is derived without locale-sensitive formatting:

1. Interpret `pairDigest` as one unsigned 256-bit big-endian integer `n`.
2. Compute `n mod 10^60`.
3. Render exactly 60 decimal digits, padding on the left with zeroes.
4. For display only, split the result into twelve groups of five digits.

The grouped spaces are not part of the value. Users must compare all 60 digits.

## Signed QR payload

The presenting device constructs the unsigned QR bytes as:

```text
unsignedQR = raw("KITHRA/CONTACT-VERIFY-QR/V1\0")
           || 0x01
           || lp16(presenterCanonicalIdentity)
           || pairDigest[32]
signature = Ed25519-detached-sign(unsignedQR, presenterSigningPrivateKey)
rawQR = unsignedQR || signature[64]
```

Sign the raw bytes directly with libsodium `crypto_sign_detached`; do not
prehash or use Ed25519ph. The text encoded in the QR image is:

```text
KITHRA:VERIFY:1:<base64url-no-padding(rawQR)>
```

The prefix and domains are case-sensitive. The parser accepts only canonical
unpadded base64url, version 1, the fixed field lengths, a canonical presenter
identity, a valid Ed25519 signature under the key inside that identity, and no
trailing data. The complete text is capped at 2,048 characters.

The verification screen already identifies the expected contact. The scanner
must require the presenter identity to equal the current relay-presented contact
identity, recompute the pair digest from its local and expected identities, and
compare that digest to the QR value. A valid QR for a different pair fails
without offering to change contacts.

The signature proves the device displaying the code holds the signing key in
the presented identity. The pair digest makes the code peer-specific, so a QR
created for another scanner does not verify. A match lets only the scanning
device pin its current view; it does not remotely alter the presenter's trust
state. Each person must scan on their own device, or both can compare the full
safety number and confirm locally.

## Local pin and fail-closed behavior

The iOS client stores a trust record in Keychain, namespaced by relay scope,
local device, contact user, and contact device. The record stores both trusted
canonical identities (from which identity and pair digests are deterministically
recomputed), candidate identities, protocol version, verification method, and
local observation/verification times. The times and method are informational and
are not part of the cryptographic identity.

Trust states are:

- `unverified`: no pin exists. Sending and accepting authenticated messages are
  disabled until out-of-band verification succeeds.
- `verified`: the local and contact identities exactly match the pin.
- `keyChanged`: the local or contact identity differs from the pin. Never
  overwrite the pin from relay data. Block sending and incoming authentication
  until the replacement identity is independently verified.

An inability to reconstruct the local identity from the authenticated session
and locally derived keys is a fatal local-identity mismatch, even though it is
reported outside the three persisted contact trust states.

All send paths, including retry/resend and background work, resolve the
recipient key from the verified pin and confirm the current contact record still
matches it. They never encrypt to a newly returned relay key first and warn
later. Incoming Message Envelope v2 signatures are verified only with the pinned
Ed25519 signing key and only after both signed identity digests match the pin.

Deleting or blocking a contact deletes its local pin together with the local
relationship. Re-adding or unblocking that person starts unverified and cannot
silently accept a replacement key. Resetting local registration removes all
local pins and replay receipts.

## Guarantees and limitations

After both users compare through an independent channel and the clients enforce
the pin, a malicious relay cannot substitute either device's X25519 or Ed25519
public key without producing a visible mismatch. Combined with authenticated
Message Envelope v2, it also cannot forge a new message or change signed
envelope fields without detection.

The relay can still observe routing metadata, withhold or reorder messages,
replay an unchanged signed envelope, lie about delivery/watch state, deny
service, and retain ciphertext contrary to policy. Clients therefore deduplicate
signed messages by `(senderIdentityDigest, clientMessageID)` within the local
device and relay scope; verification is not an availability or metadata-privacy
protocol. Device compromise, coerced users, screenshots, and
an attacker controlling the independent comparison channel remain out of scope.

Fixed cross-platform vectors are in
`testdata/protocol/kithra-identity-v1-message-v2.json`.
