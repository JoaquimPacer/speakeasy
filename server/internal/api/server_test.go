package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	cryptorand "crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/joaquimpacer/speakeasy/server/internal/db"
	"github.com/joaquimpacer/speakeasy/server/internal/storage"
)

type writeTrackingStore struct {
	storage.Store
	writes int
}

func (s *writeTrackingStore) Write(ctx context.Context, key string, data io.Reader) error {
	s.writes++
	return s.Store.Write(ctx, key, data)
}

func TestLocalRelayVerticalSlice(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "alice")
	bob := registerTestDevice(t, relay.URL, "bob")

	invite := createInvite(t, relay.URL, alice.BearerToken)
	accepted := acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)
	if accepted.ContactID != alice.User.ID {
		t.Fatalf("accepted contactID = %q, want alice %q", accepted.ContactID, alice.User.ID)
	}
	if accepted.DeviceID != alice.Device.ID {
		t.Fatalf("accepted deviceID = %q, want alice device %q", accepted.DeviceID, alice.Device.ID)
	}

	bobContact := assertHasContact(t, relay.URL, alice.BearerToken, bob.User.ID)
	aliceContact := assertHasContact(t, relay.URL, bob.BearerToken, alice.User.ID)
	if bobContact.DeviceID != bob.Device.ID {
		t.Fatalf("alice contact deviceID = %q, want bob device %q", bobContact.DeviceID, bob.Device.ID)
	}
	if aliceContact.DeviceID != alice.Device.ID {
		t.Fatalf("bob contact deviceID = %q, want alice device %q", aliceContact.DeviceID, alice.Device.ID)
	}

	envelope := validTestEnvelope(t, alice.Device.ID, bob.Device.ID)
	message := uploadTestMessage(t, relay.URL, alice.BearerToken, strings.ToUpper(bob.User.ID), strings.ToUpper(bob.Device.ID), envelope, []byte("ciphertext-video"))
	if message.Status != "sent" {
		t.Fatalf("uploaded message status = %q, want sent", message.Status)
	}
	if message.SenderDeviceID != alice.Device.ID {
		t.Fatalf("uploaded senderDeviceID = %q, want alice device %q", message.SenderDeviceID, alice.Device.ID)
	}
	if message.RecipientDeviceID != bob.Device.ID {
		t.Fatalf("uploaded recipientDeviceID = %q, want bob device %q", message.RecipientDeviceID, bob.Device.ID)
	}
	if !bytes.Equal(message.Envelope, envelope) {
		t.Fatalf("uploaded envelope = %s, want %s", message.Envelope, envelope)
	}

	messages := listMessages(t, relay.URL, bob.BearerToken)
	if len(messages) != 1 {
		t.Fatalf("bob message count = %d, want 1", len(messages))
	}
	if messages[0].ID != message.ID {
		t.Fatalf("bob message id = %q, want %q", messages[0].ID, message.ID)
	}
	if messages[0].RecipientDeviceID != bob.Device.ID {
		t.Fatalf("bob message recipientDeviceID = %q, want %q", messages[0].RecipientDeviceID, bob.Device.ID)
	}

	downloaded := downloadMessage(t, relay.URL, bob.BearerToken, strings.ToUpper(message.ID))
	if string(downloaded) != "ciphertext-video" {
		t.Fatalf("downloaded blob = %q, want ciphertext-video", string(downloaded))
	}

	delivered := acknowledgeDelivered(t, relay.URL, bob.BearerToken, strings.ToUpper(message.ID))
	if delivered.Status != "delivered" || !delivered.BlobDeleted {
		t.Fatalf("delivered response = %+v, want delivered with blobDeleted", delivered)
	}

	statusCode := downloadMessageStatus(t, relay.URL, bob.BearerToken, message.ID)
	if statusCode != http.StatusGone {
		t.Fatalf("download after delivery status = %d, want %d", statusCode, http.StatusGone)
	}

	messages = listMessages(t, relay.URL, bob.BearerToken)
	if len(messages) != 1 {
		t.Fatalf("bob message count after delivery = %d, want 1", len(messages))
	}
	if messages[0].Status != "delivered" {
		t.Fatalf("message status after delivery = %q, want delivered", messages[0].Status)
	}
	if messages[0].EncryptedBlobPath != "" {
		t.Fatalf("encryptedBlobPath after delivery = %q, want empty", messages[0].EncryptedBlobPath)
	}
}

func TestRegisterValidatesDevicePublicKeys(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(NewWithOptions(database, blobStore, Options{
		RetentionDays:          7,
		RegistrationRatePerIP:  100,
		RegistrationRateGlobal: 100,
	}).Handler())
	t.Cleanup(relay.Close)

	encodedKey := func(size int) string {
		return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x01}, size))
	}
	validKey := encodedKey(32)

	tests := []struct {
		name          string
		encryptionKey string
		signingKey    string
		wantStatus    int
	}{
		{
			name:          "valid keys",
			encryptionKey: validKey,
			signingKey:    validKey,
			wantStatus:    http.StatusCreated,
		},
		{
			name:          "encryption key too short",
			encryptionKey: encodedKey(31),
			signingKey:    validKey,
			wantStatus:    http.StatusBadRequest,
		},
		{
			name:          "encryption key too long",
			encryptionKey: encodedKey(33),
			signingKey:    validKey,
			wantStatus:    http.StatusBadRequest,
		},
		{
			name:          "signing key too short",
			encryptionKey: validKey,
			signingKey:    encodedKey(31),
			wantStatus:    http.StatusBadRequest,
		},
		{
			name:          "signing key too long",
			encryptionKey: validKey,
			signingKey:    encodedKey(33),
			wantStatus:    http.StatusBadRequest,
		},
		{
			name:          "malformed encryption key base64",
			encryptionKey: "not-base64!",
			signingKey:    validKey,
			wantStatus:    http.StatusBadRequest,
		},
		{
			name:          "malformed signing key base64",
			encryptionKey: validKey,
			signingKey:    "not-base64!",
			wantStatus:    http.StatusBadRequest,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			payload := map[string]string{
				"deviceID":            mustID(),
				"username":            "key-test-" + strings.ReplaceAll(test.name, " ", "-"),
				"deviceName":          "test device",
				"encryptionPublicKey": test.encryptionKey,
				"signingPublicKey":    test.signingKey,
			}

			var session authSessionResponse
			var target any
			if test.wantStatus == http.StatusCreated {
				target = &session
			}
			postJSON(t, relay.URL+"/auth/register", "", payload, test.wantStatus, target)

			if test.wantStatus == http.StatusCreated {
				if len(session.Device.EncryptionPublicKey) != 32 || len(session.Device.SigningPublicKey) != 32 {
					t.Fatalf("registered public key lengths = (%d, %d), want (32, 32)", len(session.Device.EncryptionPublicKey), len(session.Device.SigningPublicKey))
				}
			}
		})
	}
}

func TestRegisterValidatesUsernameForIdentityVerification(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(NewWithOptions(database, blobStore, Options{
		RetentionDays:          7,
		RegistrationRatePerIP:  100,
		RegistrationRateGlobal: 100,
	}).Handler())
	t.Cleanup(relay.Close)

	validKey := bytes.Repeat([]byte{0x01}, 32)
	tests := []struct {
		name         string
		username     string
		wantStatus   int
		wantUsername string
	}{
		{
			name:         "trims a non-empty username",
			username:     "  trimmed-username  ",
			wantStatus:   http.StatusCreated,
			wantUsername: "trimmed-username",
		},
		{
			name:         "allows exactly 128 UTF-8 bytes",
			username:     strings.Repeat("é", 64),
			wantStatus:   http.StatusCreated,
			wantUsername: strings.Repeat("é", 64),
		},
		{
			name:       "rejects empty after trimming",
			username:   " \t\n ",
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "rejects more than 128 UTF-8 bytes",
			username:   strings.Repeat("é", 65),
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "rejects ASCII control character",
			username:   "control\x00character",
			wantStatus: http.StatusBadRequest,
		},
		{
			name:       "rejects non-ASCII Unicode control character",
			username:   "control\u0085character",
			wantStatus: http.StatusBadRequest,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var session authSessionResponse
			var target any
			if test.wantStatus == http.StatusCreated {
				target = &session
			}
			postJSON(t, relay.URL+"/auth/register", "", registerRequest{
				DeviceID:            mustID(),
				Username:            test.username,
				DeviceName:          "test device",
				EncryptionPublicKey: validKey,
				SigningPublicKey:    validKey,
			}, test.wantStatus, target)

			if test.wantStatus == http.StatusCreated && session.User.Username != test.wantUsername {
				t.Fatalf("registered username = %q, want %q", session.User.Username, test.wantUsername)
			}
		})
	}

	encodedKey := base64.StdEncoding.EncodeToString(validKey)
	invalidUTF8Body := append([]byte(`{"username":"invalid-`), 0xff)
	invalidUTF8Body = append(invalidUTF8Body, []byte(`","deviceName":"test device","encryptionPublicKey":"`)...)
	invalidUTF8Body = append(invalidUTF8Body, encodedKey...)
	invalidUTF8Body = append(invalidUTF8Body, []byte(`","signingPublicKey":"`)...)
	invalidUTF8Body = append(invalidUTF8Body, encodedKey...)
	invalidUTF8Body = append(invalidUTF8Body, []byte(`"}`)...)
	request := authedRequest(t, http.MethodPost, relay.URL+"/auth/register", "", bytes.NewReader(invalidUTF8Body))
	request.Header.Set("Content-Type", "application/json")
	doRequest(t, request, http.StatusBadRequest, nil)
}

func TestRegisterRetryRequiresPrivateKeyRecovery(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(NewWithOptions(database, blobStore, Options{
		RetentionDays:          7,
		RegistrationRatePerIP:  100,
		RegistrationRateGlobal: 100,
	}).Handler())
	t.Cleanup(relay.Close)

	publicKey, privateKey, err := ed25519.GenerateKey(cryptorand.Reader)
	if err != nil {
		t.Fatalf("generate signing key: %v", err)
	}
	request := registerRequest{
		DeviceID:            mustID(),
		Username:            "retry-alice",
		DeviceName:          "Alice iPhone",
		EncryptionPublicKey: bytes.Repeat([]byte{0x31}, 32),
		SigningPublicKey:    publicKey,
	}
	for _, invalidDeviceID := range []string{"", "not-a-uuid", "00000000-0000-0000-0000-000000000000"} {
		invalid := request
		invalid.DeviceID = invalidDeviceID
		postJSON(t, relay.URL+"/auth/register", "", invalid, http.StatusBadRequest, nil)
	}

	var first authSessionResponse
	postJSON(t, relay.URL+"/auth/register", "", request, http.StatusCreated, &first)
	// Simulate a committed registration whose response was lost. Replaying the
	// public registration fields must not mint a second bearer token.
	conflictBody := postRegistrationConflict(t, relay.URL, request)

	for table, want := range map[string]int{"users": 1, "devices": 1, "sessions": 1} {
		var got int
		if err := database.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+table).Scan(&got); err != nil {
			t.Fatalf("count %s: %v", table, err)
		}
		if got != want {
			t.Fatalf("%s count = %d, want %d", table, got, want)
		}
	}

	// Recovery uses the existing signed challenge flow, so possession of the
	// device signing private key is required before a fresh session is issued.
	challenge := requestAuthChallenge(t, relay.URL, request.Username, request.DeviceID, http.StatusCreated)
	_, wrongPrivateKey, err := ed25519.GenerateKey(cryptorand.Reader)
	if err != nil {
		t.Fatalf("generate wrong signing key: %v", err)
	}
	loginWithChallenge(
		t,
		relay.URL,
		request.Username,
		request.DeviceID,
		challenge.ChallengeID,
		signLoginChallenge(wrongPrivateKey, challenge.Challenge),
		http.StatusUnauthorized,
	)
	recovered := loginWithChallenge(
		t,
		relay.URL,
		request.Username,
		request.DeviceID,
		challenge.ChallengeID,
		signLoginChallenge(privateKey, challenge.Challenge),
		http.StatusOK,
	)
	if recovered.User != first.User || recovered.Device.ID != first.Device.ID ||
		recovered.Device.CreatedAt != first.Device.CreatedAt ||
		!bytes.Equal(recovered.Device.EncryptionPublicKey, first.Device.EncryptionPublicKey) ||
		!bytes.Equal(recovered.Device.SigningPublicKey, first.Device.SigningPublicKey) {
		t.Fatalf("recovered session = %+v, want original identity %+v", recovered, first)
	}
	if recovered.BearerToken == first.BearerToken {
		t.Fatal("challenge login reused registration bearer token")
	}
	listMessages(t, relay.URL, first.BearerToken)
	listMessages(t, relay.URL, recovered.BearerToken)

	conflicts := []struct {
		name    string
		request registerRequest
	}{
		{name: "username", request: func() registerRequest { changed := request; changed.Username = "retry-mallory"; return changed }()},
		{name: "device name", request: func() registerRequest { changed := request; changed.DeviceName = "Other iPhone"; return changed }()},
		{name: "encryption key", request: func() registerRequest {
			changed := request
			changed.EncryptionPublicKey = bytes.Repeat([]byte{0x41}, 32)
			return changed
		}()},
		{name: "signing key", request: func() registerRequest {
			changed := request
			changed.SigningPublicKey = bytes.Repeat([]byte{0x42}, 32)
			return changed
		}()},
		{name: "same username with another device", request: func() registerRequest { changed := request; changed.DeviceID = mustID(); return changed }()},
	}
	for _, test := range conflicts {
		t.Run("rejects conflicting "+test.name, func(t *testing.T) {
			if got := postRegistrationConflict(t, relay.URL, test.request); got != conflictBody {
				t.Fatalf("conflict body = %q, want generic %q", got, conflictBody)
			}
		})
	}
}

func TestConcurrentRegistrationCreatesOneIdentity(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })
	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}
	relay := httptest.NewServer(NewWithOptions(database, blobStore, Options{
		RetentionDays:          7,
		RegistrationRatePerIP:  100,
		RegistrationRateGlobal: 100,
	}).Handler())
	t.Cleanup(relay.Close)

	publicKey, privateKey, err := ed25519.GenerateKey(cryptorand.Reader)
	if err != nil {
		t.Fatalf("generate signing key: %v", err)
	}
	registration := registerRequest{
		DeviceID:            mustID(),
		Username:            "concurrent-register",
		DeviceName:          "Concurrent iPhone",
		EncryptionPublicKey: bytes.Repeat([]byte{0x51}, 32),
		SigningPublicKey:    publicKey,
	}
	body, err := json.Marshal(registration)
	if err != nil {
		t.Fatalf("marshal registration: %v", err)
	}
	type result struct {
		status int
		body   []byte
		err    error
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	for range 2 {
		go func() {
			<-start
			response, requestErr := http.Post(
				relay.URL+"/auth/register",
				"application/json",
				bytes.NewReader(body),
			)
			if requestErr != nil {
				results <- result{err: requestErr}
				return
			}
			defer response.Body.Close()
			responseBody, readErr := io.ReadAll(response.Body)
			results <- result{status: response.StatusCode, body: responseBody, err: readErr}
		}()
	}
	close(start)

	createdCount := 0
	conflictCount := 0
	var created authSessionResponse
	for range 2 {
		result := <-results
		if result.err != nil {
			t.Fatalf("concurrent registration: %v", result.err)
		}
		switch result.status {
		case http.StatusCreated:
			createdCount++
			if err := json.Unmarshal(result.body, &created); err != nil {
				t.Fatalf("decode created registration: %v; body = %s", err, result.body)
			}
		case http.StatusConflict:
			conflictCount++
			if got, want := string(result.body), registrationConflictMessage+"\n"; got != want {
				t.Fatalf("conflict body = %q, want %q", got, want)
			}
		default:
			t.Fatalf("concurrent registration status = %d, body = %s", result.status, result.body)
		}
	}
	if createdCount != 1 || conflictCount != 1 {
		t.Fatalf("concurrent results = %d created, %d conflict; want 1 and 1", createdCount, conflictCount)
	}
	for table, want := range map[string]int{"users": 1, "devices": 1, "sessions": 1} {
		var got int
		if err := database.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+table).Scan(&got); err != nil {
			t.Fatalf("count %s: %v", table, err)
		}
		if got != want {
			t.Fatalf("%s count = %d, want %d", table, got, want)
		}
	}

	challenge := requestAuthChallenge(t, relay.URL, registration.Username, registration.DeviceID, http.StatusCreated)
	recovered := loginWithChallenge(
		t,
		relay.URL,
		registration.Username,
		registration.DeviceID,
		challenge.ChallengeID,
		signLoginChallenge(privateKey, challenge.Challenge),
		http.StatusOK,
	)
	if recovered.User != created.User || recovered.Device.ID != created.Device.ID ||
		!bytes.Equal(recovered.Device.SigningPublicKey, created.Device.SigningPublicKey) {
		t.Fatalf("recovered identity = %+v, want %+v", recovered, created)
	}
	listMessages(t, relay.URL, recovered.BearerToken)
}

func TestUploadRejectsInvalidAuthenticatedEnvelopeBeforeBlobWrite(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	localBlobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}
	blobStore := &writeTrackingStore{Store: localBlobStore}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "envelope-alice")
	bob := registerTestDevice(t, relay.URL, "envelope-bob")
	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)

	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{
			name: "legacy version",
			mutate: func(envelope map[string]any) {
				envelope["version"] = 1
			},
		},
		{
			name: "malformed field type",
			mutate: func(envelope map[string]any) {
				envelope["version"] = "2"
			},
		},
		{
			name: "unknown envelope field",
			mutate: func(envelope map[string]any) {
				envelope["futureUnsignedField"] = "poison"
			},
		},
		{
			name: "malformed client message ID",
			mutate: func(envelope map[string]any) {
				envelope["clientMessageID"] = "not-a-uuid"
			},
		},
		{
			name: "zero client message ID",
			mutate: func(envelope map[string]any) {
				envelope["clientMessageID"] = "00000000-0000-0000-0000-000000000000"
			},
		},
		{
			name: "sender device mismatch",
			mutate: func(envelope map[string]any) {
				envelope["senderDeviceID"] = mustID()
			},
		},
		{
			name: "recipient device mismatch",
			mutate: func(envelope map[string]any) {
				envelope["recipientDeviceID"] = mustID()
			},
		},
		{
			name: "sender identity digest too short",
			mutate: func(envelope map[string]any) {
				envelope["senderIdentityDigest"] = bytes.Repeat([]byte{0x01}, 31)
			},
		},
		{
			name: "recipient identity digest too long",
			mutate: func(envelope map[string]any) {
				envelope["recipientIdentityDigest"] = bytes.Repeat([]byte{0x02}, 33)
			},
		},
		{
			name: "malformed identity digest base64",
			mutate: func(envelope map[string]any) {
				envelope["senderIdentityDigest"] = "not-base64!"
			},
		},
		{
			name: "wrong authentication algorithm",
			mutate: func(envelope map[string]any) {
				envelope["authenticationAlgorithm"] = "ed25519"
			},
		},
		{
			name: "signature too short",
			mutate: func(envelope map[string]any) {
				envelope["signature"] = bytes.Repeat([]byte{0x03}, 63)
			},
		},
		{
			name: "malformed signature base64",
			mutate: func(envelope map[string]any) {
				envelope["signature"] = "not-base64!"
			},
		},
		{
			name: "signature too long",
			mutate: func(envelope map[string]any) {
				envelope["signature"] = bytes.Repeat([]byte{0x03}, 65)
			},
		},
		{
			name: "wrong media algorithm",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["algorithm"] = "xchacha20poly1305"
			},
		},
		{
			name: "unknown media field",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["unsignedCaption"] = "poison"
			},
		},
		{
			name: "media nonce too short",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["nonce"] = bytes.Repeat([]byte{0x04}, 23)
			},
		},
		{
			name: "media nonce too long",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["nonce"] = bytes.Repeat([]byte{0x04}, 25)
			},
		},
		{
			name: "malformed media nonce base64",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["nonce"] = "not-base64!"
			},
		},
		{
			name: "media ciphertext hash too short",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["ciphertextHash"] = bytes.Repeat([]byte{0x04}, 31)
			},
		},
		{
			name: "media ciphertext hash too long",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["ciphertextHash"] = bytes.Repeat([]byte{0x04}, 33)
			},
		},
		{
			name: "missing media ciphertext hash",
			mutate: func(envelope map[string]any) {
				delete(envelope["media"].(map[string]any), "ciphertextHash")
			},
		},
		{
			name: "missing media MIME type",
			mutate: func(envelope map[string]any) {
				delete(envelope["media"].(map[string]any), "mimeType")
			},
		},
		{
			name: "wrong media MIME type field type",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["mimeType"] = 42
			},
		},
		{
			name: "empty media MIME type",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["mimeType"] = ""
			},
		},
		{
			name: "oversized media MIME type",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["mimeType"] = strings.Repeat("m", maxEnvelopeMIMETypeUTF8Bytes+1)
			},
		},
		{
			name: "wrong media duration field type",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["durationSeconds"] = "NaN"
			},
		},
		{
			name: "negative media duration",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["durationSeconds"] = -0.001
			},
		},
		{
			name: "overflowing media duration exponent",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["durationSeconds"] = json.RawMessage("1e999")
			},
		},
		{
			name: "finite media duration overflows canonical milliseconds",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["durationSeconds"] = 1e308
			},
		},
		{
			name: "wrong content key algorithm",
			mutate: func(envelope map[string]any) {
				envelope["contentKey"].(map[string]any)["algorithm"] = "crypto-box-seal"
			},
		},
		{
			name: "content key too short",
			mutate: func(envelope map[string]any) {
				envelope["contentKey"].(map[string]any)["encryptedContentKey"] = bytes.Repeat([]byte{0x05}, 79)
			},
		},
		{
			name: "content key too long",
			mutate: func(envelope map[string]any) {
				envelope["contentKey"].(map[string]any)["encryptedContentKey"] = bytes.Repeat([]byte{0x05}, 81)
			},
		},
		{
			name: "missing content key",
			mutate: func(envelope map[string]any) {
				delete(envelope, "contentKey")
			},
		},
		{
			name: "malformed content key base64",
			mutate: func(envelope map[string]any) {
				envelope["contentKey"].(map[string]any)["encryptedContentKey"] = "not-base64!"
			},
		},
		{
			name: "unknown content key field",
			mutate: func(envelope map[string]any) {
				envelope["contentKey"].(map[string]any)["untrustedHint"] = "poison"
			},
		},
		{
			name: "wrong recipient fingerprint field type",
			mutate: func(envelope map[string]any) {
				envelope["contentKey"].(map[string]any)["recipientPublicKeyFingerprint"] = true
			},
		},
		{
			name: "empty recipient fingerprint",
			mutate: func(envelope map[string]any) {
				envelope["contentKey"].(map[string]any)["recipientPublicKeyFingerprint"] = ""
			},
		},
		{
			name: "oversized recipient fingerprint",
			mutate: func(envelope map[string]any) {
				envelope["contentKey"].(map[string]any)["recipientPublicKeyFingerprint"] = strings.Repeat("f", maxKeyFingerprintUTF8Bytes+1)
			},
		},
		{
			name: "wrong optional sender content key algorithm",
			mutate: func(envelope map[string]any) {
				key := validTestContentKeyValue(0x06)
				key["algorithm"] = "crypto-box-seal"
				envelope["senderContentKey"] = key
			},
		},
		{
			name: "optional sender content key too short",
			mutate: func(envelope map[string]any) {
				key := validTestContentKeyValue(0x06)
				key["encryptedContentKey"] = bytes.Repeat([]byte{0x06}, 79)
				envelope["senderContentKey"] = key
			},
		},
		{
			name: "optional sender content key too long",
			mutate: func(envelope map[string]any) {
				key := validTestContentKeyValue(0x06)
				key["encryptedContentKey"] = bytes.Repeat([]byte{0x06}, 81)
				envelope["senderContentKey"] = key
			},
		},
		{
			name: "optional sender content key missing sealed key",
			mutate: func(envelope map[string]any) {
				envelope["senderContentKey"] = map[string]any{"algorithm": "crypto_box_seal"}
			},
		},
		{
			name: "optional sender content key control-character fingerprint",
			mutate: func(envelope map[string]any) {
				key := validTestContentKeyValue(0x06)
				key["recipientPublicKeyFingerprint"] = "fingerprint\n"
				envelope["senderContentKey"] = key
			},
		},
		{
			name: "wrong optional thumbnail algorithm",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				thumbnail["algorithm"] = "xchacha20poly1305"
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "optional thumbnail nonce too short",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				thumbnail["nonce"] = bytes.Repeat([]byte{0x06}, 23)
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "optional thumbnail nonce too long",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				thumbnail["nonce"] = bytes.Repeat([]byte{0x06}, 25)
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "optional thumbnail missing blob path",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				delete(thumbnail, "encryptedBlobPath")
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "optional thumbnail empty blob path",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				thumbnail["encryptedBlobPath"] = ""
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "optional thumbnail oversized blob path",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				thumbnail["encryptedBlobPath"] = strings.Repeat("p", maxThumbnailPathUTF8Bytes+1)
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "optional thumbnail missing ciphertext hash",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				delete(thumbnail, "ciphertextHash")
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "optional thumbnail ciphertext hash too short",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				thumbnail["ciphertextHash"] = bytes.Repeat([]byte{0x07}, 31)
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "optional thumbnail ciphertext hash too long",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				thumbnail["ciphertextHash"] = bytes.Repeat([]byte{0x07}, 33)
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "unknown optional thumbnail field",
			mutate: func(envelope map[string]any) {
				thumbnail := validTestThumbnailValue()
				thumbnail["plaintextHint"] = "poison"
				envelope["media"].(map[string]any)["thumbnail"] = thumbnail
			},
		},
		{
			name: "missing created at",
			mutate: func(envelope map[string]any) {
				delete(envelope, "createdAt")
			},
		},
		{
			name: "invalid created at",
			mutate: func(envelope map[string]any) {
				envelope["createdAt"] = "not-a-timestamp"
			},
		},
		{
			name: "wrong created at field type",
			mutate: func(envelope map[string]any) {
				envelope["createdAt"] = 1_785_691_112
			},
		},
		{
			name: "fractional created at not accepted by Foundation ISO8601 strategy",
			mutate: func(envelope map[string]any) {
				envelope["createdAt"] = "2026-08-02T17:18:32.125Z"
			},
		},
		{
			name: "offset created at rejected in favor of one cross-platform encoding",
			mutate: func(envelope map[string]any) {
				envelope["createdAt"] = "2026-08-02T12:18:32-05:00"
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			envelopeValue := validTestEnvelopeValue(alice.Device.ID, bob.Device.ID)
			test.mutate(envelopeValue)
			envelope, err := json.Marshal(envelopeValue)
			if err != nil {
				t.Fatalf("marshal envelope: %v", err)
			}

			status := uploadTestMessageStatus(
				t,
				relay.URL,
				alice.BearerToken,
				bob.User.ID,
				bob.Device.ID,
				envelope,
				[]byte("ciphertext-video"),
			)
			if status != http.StatusBadRequest {
				t.Fatalf("upload status = %d, want %d", status, http.StatusBadRequest)
			}

			if blobStore.writes != 0 {
				t.Fatalf("invalid envelope called blob store Write %d times, want 0", blobStore.writes)
			}
		})
	}

	var messages []messageResponse
	getJSON(t, relay.URL+"/messages", bob.BearerToken, http.StatusOK, &messages)
	if len(messages) != 0 {
		t.Fatalf("invalid envelopes poisoned message list with %d stored messages, want 0", len(messages))
	}
}

func TestUploadRejectsOversizedAndUnknownMetadataBeforeBlobWrite(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	localBlobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}
	blobStore := &writeTrackingStore{Store: localBlobStore}
	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "metadata-alice")
	recipientID := mustID()
	recipientDeviceID := mustID()

	tests := []struct {
		name       string
		wantStatus int
		mutate     func(map[string]any)
	}{
		{
			name:       "unknown metadata field",
			wantStatus: http.StatusBadRequest,
			mutate: func(metadata map[string]any) {
				metadata["unsignedPadding"] = "poison"
			},
		},
		{
			name:       "oversized authenticated envelope",
			wantStatus: http.StatusBadRequest,
			mutate: func(metadata map[string]any) {
				envelopeValue := validTestEnvelopeValue(alice.Device.ID, recipientDeviceID)
				envelopeValue["unknownPadding"] = strings.Repeat("e", maxAuthenticatedEnvelopeBytes)
				envelope, err := json.Marshal(envelopeValue)
				if err != nil {
					t.Fatalf("marshal oversized envelope: %v", err)
				}
				if len(envelope) <= maxAuthenticatedEnvelopeBytes {
					t.Fatalf("oversized envelope length = %d, want more than %d", len(envelope), maxAuthenticatedEnvelopeBytes)
				}
				metadata["envelope"] = json.RawMessage(envelope)
			},
		},
		{
			name:       "oversized metadata part",
			wantStatus: http.StatusRequestEntityTooLarge,
			mutate: func(metadata map[string]any) {
				metadata["unsignedPadding"] = strings.Repeat("m", maxUploadMetadataBytes)
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			metadata := map[string]any{
				"recipientID":       recipientID,
				"recipientDeviceID": recipientDeviceID,
				"envelope":          validTestEnvelope(t, alice.Device.ID, recipientDeviceID),
				"blobSize":          1,
			}
			test.mutate(metadata)
			metadataJSON, err := json.Marshal(metadata)
			if err != nil {
				t.Fatalf("marshal metadata: %v", err)
			}
			if test.wantStatus == http.StatusRequestEntityTooLarge && len(metadataJSON) <= maxUploadMetadataBytes {
				t.Fatalf("oversized metadata length = %d, want more than %d", len(metadataJSON), maxUploadMetadataBytes)
			}

			request := newUploadRequestWithMetadata(t, relay.URL, alice.BearerToken, metadataJSON, []byte("x"))
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatalf("upload metadata: %v", err)
			}
			response.Body.Close()
			if response.StatusCode != test.wantStatus {
				t.Fatalf("upload status = %d, want %d", response.StatusCode, test.wantStatus)
			}
			if blobStore.writes != 0 {
				t.Fatalf("invalid metadata called blob store Write %d times, want 0", blobStore.writes)
			}
		})
	}
}

func TestUploadAcceptsAuthenticatedEnvelopeOptionalStructures(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "optional-alice")
	bob := registerTestDevice(t, relay.URL, "optional-bob")
	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)

	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{
			name: "explicit null optionals",
			mutate: func(envelope map[string]any) {
				envelope["senderContentKey"] = nil
				media := envelope["media"].(map[string]any)
				media["durationSeconds"] = nil
				media["thumbnail"] = nil
				envelope["contentKey"].(map[string]any)["recipientPublicKeyFingerprint"] = nil
			},
		},
		{
			name: "valid finite duration",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["durationSeconds"] = 42.125
			},
		},
		{
			name: "valid optional sender content key",
			mutate: func(envelope map[string]any) {
				key := validTestContentKeyValue(0x06)
				key["recipientPublicKeyFingerprint"] = "j0DFrbaPJWJK5bIU6nZ6bg=="
				envelope["senderContentKey"] = key
			},
		},
		{
			name: "valid recipient key fingerprint",
			mutate: func(envelope map[string]any) {
				envelope["contentKey"].(map[string]any)["recipientPublicKeyFingerprint"] = "eaYx7t4b+cmPEgMs3q3Q5w=="
			},
		},
		{
			name: "valid optional thumbnail",
			mutate: func(envelope map[string]any) {
				envelope["media"].(map[string]any)["thumbnail"] = validTestThumbnailValue()
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			envelopeValue := validTestEnvelopeValue(alice.Device.ID, bob.Device.ID)
			test.mutate(envelopeValue)
			envelope, err := json.Marshal(envelopeValue)
			if err != nil {
				t.Fatalf("marshal envelope: %v", err)
			}

			status := uploadTestMessageStatus(
				t,
				relay.URL,
				alice.BearerToken,
				bob.User.ID,
				bob.Device.ID,
				envelope,
				[]byte("ciphertext-video"),
			)
			if status != http.StatusCreated {
				t.Fatalf("upload status = %d, want %d", status, http.StatusCreated)
			}
		})
	}
}

func TestAuthenticatedEnvelopeFixedVectorsMatchRelayWireSchema(t *testing.T) {
	fixturePath := filepath.Join("..", "..", "..", "testdata", "protocol", "kithra-identity-v1-message-v2.json")
	fixtureData, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("read protocol vectors: %v", err)
	}

	var fixture struct {
		MessageEnvelopeV2 struct {
			Cases []struct {
				Name     string          `json:"name"`
				Envelope json.RawMessage `json:"envelope"`
			} `json:"cases"`
		} `json:"messageEnvelopeV2"`
	}
	if err := json.Unmarshal(fixtureData, &fixture); err != nil {
		t.Fatalf("decode protocol vectors: %v", err)
	}
	if len(fixture.MessageEnvelopeV2.Cases) == 0 {
		t.Fatal("protocol vectors contain no authenticated message cases")
	}

	for _, testCase := range fixture.MessageEnvelopeV2.Cases {
		t.Run(testCase.Name, func(t *testing.T) {
			var route struct {
				SenderDeviceID    string `json:"senderDeviceID"`
				RecipientDeviceID string `json:"recipientDeviceID"`
			}
			if err := json.Unmarshal(testCase.Envelope, &route); err != nil {
				t.Fatalf("decode vector route: %v", err)
			}
			if err := validateAuthenticatedEnvelope(
				testCase.Envelope,
				route.SenderDeviceID,
				route.RecipientDeviceID,
			); err != nil {
				t.Fatalf("relay rejected Swift-decoded protocol vector: %v", err)
			}
		})
	}
}

func TestDeleteAccountRemovesServerRecordsAndBlobs(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "delete-alice")
	bob := registerTestDevice(t, relay.URL, "delete-bob")

	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)
	envelope := validTestEnvelope(t, alice.Device.ID, bob.Device.ID)
	message := uploadTestMessage(t, relay.URL, alice.BearerToken, bob.User.ID, bob.Device.ID, envelope, []byte("pending-ciphertext-video"))

	if statusCode := downloadMessageStatus(t, relay.URL, bob.BearerToken, message.ID); statusCode != http.StatusOK {
		t.Fatalf("download before account deletion status = %d, want %d", statusCode, http.StatusOK)
	}

	deleteAccount(t, relay.URL, bob.BearerToken)

	if statusCode := getStatus(t, relay.URL+"/contacts", bob.BearerToken); statusCode != http.StatusUnauthorized {
		t.Fatalf("deleted account auth status = %d, want %d", statusCode, http.StatusUnauthorized)
	}
	if statusCode := downloadMessageStatus(t, relay.URL, alice.BearerToken, message.ID); statusCode != http.StatusNotFound {
		t.Fatalf("download after account deletion status = %d, want %d", statusCode, http.StatusNotFound)
	}

	aliceContacts := listContacts(t, relay.URL, alice.BearerToken)
	for _, contact := range aliceContacts {
		if contact.ContactID == bob.User.ID {
			t.Fatalf("deleted account remained in contacts: %+v", contact)
		}
	}
}

func TestDeleteContactRemovesOnlyRequesterContact(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "delete-contact-alice")
	bob := registerTestDevice(t, relay.URL, "delete-contact-bob")
	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)

	assertHasContact(t, relay.URL, alice.BearerToken, bob.User.ID)
	assertHasContact(t, relay.URL, bob.BearerToken, alice.User.ID)

	deleteContact(t, relay.URL, alice.BearerToken, bob.User.ID)

	aliceContacts := listContacts(t, relay.URL, alice.BearerToken)
	for _, contact := range aliceContacts {
		if contact.ContactID == bob.User.ID {
			t.Fatalf("deleted contact remained in alice contacts: %+v", contact)
		}
	}
	assertHasContact(t, relay.URL, bob.BearerToken, alice.User.ID)
}

func TestBlockContactRemovesContactAndRejectsBlockedSender(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "block-alice")
	bob := registerTestDevice(t, relay.URL, "block-bob")
	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)

	blockContact(t, relay.URL, alice.BearerToken, bob.User.ID)

	aliceContacts := listContacts(t, relay.URL, alice.BearerToken)
	for _, contact := range aliceContacts {
		if contact.ContactID == bob.User.ID {
			t.Fatalf("blocked contact remained in alice contacts: %+v", contact)
		}
	}
	assertHasContact(t, relay.URL, bob.BearerToken, alice.User.ID)

	envelope := validTestEnvelope(t, bob.Device.ID, alice.Device.ID)
	statusCode := uploadTestMessageStatus(t, relay.URL, bob.BearerToken, alice.User.ID, alice.Device.ID, envelope, []byte("blocked-ciphertext-video"))
	if statusCode != http.StatusForbidden {
		t.Fatalf("blocked sender upload status = %d, want %d", statusCode, http.StatusForbidden)
	}
}

func TestReportContactStoresMetadataOnlyReport(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "report-alice")
	bob := registerTestDevice(t, relay.URL, "report-bob")

	reportContact(t, relay.URL, alice.BearerToken, bob.User.ID)

	var reportCount int
	if err := database.QueryRowContext(
		ctx,
		`SELECT COUNT(*) FROM reports
		  WHERE reporter_user_id = ? AND reported_user_id = ? AND reason = 'contact'`,
		alice.User.ID,
		bob.User.ID,
	).Scan(&reportCount); err != nil {
		t.Fatalf("count reports: %v", err)
	}
	if reportCount != 1 {
		t.Fatalf("report count = %d, want 1", reportCount)
	}
}

func registerTestDevice(t *testing.T, baseURL string, username string) authSessionResponse {
	t.Helper()

	var session authSessionResponse
	postJSON(t, baseURL+"/auth/register", "", registerRequest{
		DeviceID:            mustID(),
		Username:            username,
		DeviceName:          username + " iPhone",
		EncryptionPublicKey: []byte(strings.Repeat("e", 32)),
		SigningPublicKey:    []byte(strings.Repeat("s", 32)),
	}, http.StatusCreated, &session)
	return session
}

func validTestEnvelope(t *testing.T, senderDeviceID string, recipientDeviceID string) json.RawMessage {
	t.Helper()

	envelope, err := json.Marshal(validTestEnvelopeValue(senderDeviceID, recipientDeviceID))
	if err != nil {
		t.Fatalf("marshal valid envelope: %v", err)
	}
	return envelope
}

func validTestEnvelopeValue(senderDeviceID string, recipientDeviceID string) map[string]any {
	return map[string]any{
		"version":                 2,
		"clientMessageID":         mustID(),
		"senderDeviceID":          senderDeviceID,
		"recipientDeviceID":       recipientDeviceID,
		"senderIdentityDigest":    bytes.Repeat([]byte{0x01}, 32),
		"recipientIdentityDigest": bytes.Repeat([]byte{0x02}, 32),
		"authenticationAlgorithm": "Ed25519",
		"signature":               bytes.Repeat([]byte{0x03}, 64),
		"media": map[string]any{
			"algorithm":      "XChaCha20-Poly1305",
			"nonce":          bytes.Repeat([]byte{0x04}, 24),
			"ciphertextHash": bytes.Repeat([]byte{0x04}, 32),
			"mimeType":       "video/mp4",
		},
		"contentKey": validTestContentKeyValue(0x05),
		"createdAt":  time.Now().UTC().Truncate(time.Second).Format(authenticatedCreatedAtLayout),
	}
}

func validTestContentKeyValue(fill byte) map[string]any {
	return map[string]any{
		"algorithm":           "crypto_box_seal",
		"encryptedContentKey": bytes.Repeat([]byte{fill}, 80),
	}
}

func validTestThumbnailValue() map[string]any {
	return map[string]any{
		"algorithm":         "XChaCha20-Poly1305",
		"nonce":             bytes.Repeat([]byte{0x06}, 24),
		"encryptedBlobPath": "encrypted-thumbnails/example.bin",
		"ciphertextHash":    bytes.Repeat([]byte{0x07}, 32),
	}
}

func createInvite(t *testing.T, baseURL string, token string) inviteResponse {
	t.Helper()

	var invite inviteResponse
	postJSON(t, baseURL+"/contacts/invite", token, map[string]any{}, http.StatusCreated, &invite)
	if invite.Code == "" {
		t.Fatalf("invite code is empty")
	}
	return invite
}

func acceptInvite(t *testing.T, baseURL string, token string, code string) contactResponse {
	t.Helper()

	var contact contactResponse
	postJSON(t, baseURL+"/contacts/accept", token, acceptInviteRequest{Code: code}, http.StatusOK, &contact)
	return contact
}

func assertHasContact(t *testing.T, baseURL string, token string, contactID string) contactResponse {
	t.Helper()

	var contacts []contactResponse
	getJSON(t, baseURL+"/contacts", token, http.StatusOK, &contacts)
	for _, contact := range contacts {
		if contact.ContactID == contactID {
			if contact.DeviceID == "" {
				t.Fatalf("contact %q has empty deviceID", contactID)
			}
			return contact
		}
	}
	t.Fatalf("contact %q not found in %+v", contactID, contacts)
	return contactResponse{}
}

func listContacts(t *testing.T, baseURL string, token string) []contactResponse {
	t.Helper()

	var contacts []contactResponse
	getJSON(t, baseURL+"/contacts", token, http.StatusOK, &contacts)
	return contacts
}

func uploadTestMessage(t *testing.T, baseURL string, token string, recipientID string, recipientDeviceID string, envelope json.RawMessage, blob []byte) messageResponse {
	t.Helper()

	request := newUploadRequest(t, baseURL, token, recipientID, recipientDeviceID, envelope, blob)
	var message messageResponse
	doRequest(t, request, http.StatusCreated, &message)
	return message
}

func uploadTestMessageStatus(t *testing.T, baseURL string, token string, recipientID string, recipientDeviceID string, envelope json.RawMessage, blob []byte) int {
	t.Helper()

	request := newUploadRequest(t, baseURL, token, recipientID, recipientDeviceID, envelope, blob)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("upload message status: %v", err)
	}
	defer response.Body.Close()
	return response.StatusCode
}

func newUploadRequest(t *testing.T, baseURL string, token string, recipientID string, recipientDeviceID string, envelope json.RawMessage, blob []byte) *http.Request {
	t.Helper()

	metadata, err := json.Marshal(uploadMetadata{
		RecipientID:       recipientID,
		RecipientDeviceID: recipientDeviceID,
		Envelope:          envelope,
		BlobSize:          int64(len(blob)),
		DurationMs:        42000,
	})
	if err != nil {
		t.Fatalf("marshal metadata: %v", err)
	}
	return newUploadRequestWithMetadata(t, baseURL, token, metadata, blob)
}

func newUploadRequestWithMetadata(t *testing.T, baseURL string, token string, metadata []byte, blob []byte) *http.Request {
	t.Helper()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)

	metadataPart, err := writer.CreateFormField("metadata")
	if err != nil {
		t.Fatalf("create metadata part: %v", err)
	}
	if _, err := metadataPart.Write(metadata); err != nil {
		t.Fatalf("write metadata part: %v", err)
	}

	blobPart, err := writer.CreateFormFile("blob", "message.blob")
	if err != nil {
		t.Fatalf("create blob part: %v", err)
	}
	if _, err := blobPart.Write(blob); err != nil {
		t.Fatalf("write blob part: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}

	request, err := http.NewRequest(http.MethodPost, baseURL+"/messages", &body)
	if err != nil {
		t.Fatalf("new upload request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	return request
}

func listMessages(t *testing.T, baseURL string, token string) []messageResponse {
	t.Helper()

	var messages []messageResponse
	getJSON(t, baseURL+"/messages", token, http.StatusOK, &messages)
	return messages
}

func downloadMessage(t *testing.T, baseURL string, token string, messageID string) []byte {
	t.Helper()

	request := authedRequest(t, http.MethodGet, baseURL+"/messages/"+messageID, token, nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("download message: %v", err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read download body: %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("download status = %d, body = %s", response.StatusCode, string(body))
	}
	return body
}

func downloadMessageStatus(t *testing.T, baseURL string, token string, messageID string) int {
	t.Helper()

	request := authedRequest(t, http.MethodGet, baseURL+"/messages/"+messageID, token, nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("download message status: %v", err)
	}
	defer response.Body.Close()
	return response.StatusCode
}

func acknowledgeDelivered(t *testing.T, baseURL string, token string, messageID string) deliveredResponse {
	t.Helper()

	var delivered deliveredResponse
	postJSON(t, baseURL+"/messages/"+messageID+"/delivered", token, map[string]any{}, http.StatusOK, &delivered)
	return delivered
}

func deleteAccount(t *testing.T, baseURL string, token string) {
	t.Helper()

	request := authedRequest(t, http.MethodDelete, baseURL+"/account", token, nil)
	doRequest(t, request, http.StatusNoContent, nil)
}

func deleteContact(t *testing.T, baseURL string, token string, contactID string) {
	t.Helper()

	request := authedRequest(t, http.MethodDelete, baseURL+"/contacts/"+contactID, token, nil)
	doRequest(t, request, http.StatusNoContent, nil)
}

func blockContact(t *testing.T, baseURL string, token string, blockedUserID string) {
	t.Helper()

	postJSON(t, baseURL+"/blocks", token, blockRequest{BlockedUserID: blockedUserID}, http.StatusNoContent, nil)
}

func reportContact(t *testing.T, baseURL string, token string, reportedUserID string) {
	t.Helper()

	postJSON(t, baseURL+"/reports", token, reportRequest{
		ReportedUserID: reportedUserID,
		Reason:         "contact",
		Details:        "metadata-only report",
	}, http.StatusNoContent, nil)
}

func getStatus(t *testing.T, url string, token string) int {
	t.Helper()

	response, err := http.DefaultClient.Do(authedRequest(t, http.MethodGet, url, token, nil))
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer response.Body.Close()
	return response.StatusCode
}

func getJSON(t *testing.T, url string, token string, wantStatus int, target any) {
	t.Helper()
	doRequest(t, authedRequest(t, http.MethodGet, url, token, nil), wantStatus, target)
}

func postJSON(t *testing.T, url string, token string, payload any, wantStatus int, target any) {
	t.Helper()

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal JSON body: %v", err)
	}

	request := authedRequest(t, http.MethodPost, url, token, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	doRequest(t, request, wantStatus, target)
}

func postRegistrationConflict(t *testing.T, baseURL string, payload registerRequest) string {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal registration conflict: %v", err)
	}
	request := authedRequest(t, http.MethodPost, baseURL+"/auth/register", "", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("POST registration conflict: %v", err)
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read registration conflict: %v", err)
	}
	if response.StatusCode != http.StatusConflict {
		t.Fatalf("registration conflict status = %d, want %d; body = %s", response.StatusCode, http.StatusConflict, responseBody)
	}
	return string(responseBody)
}

func authedRequest(t *testing.T, method string, url string, token string, body io.Reader) *http.Request {
	t.Helper()

	request, err := http.NewRequest(method, url, body)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	return request
}

func doRequest(t *testing.T, request *http.Request, wantStatus int, target any) {
	t.Helper()

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("%s %s: %v", request.Method, request.URL, err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read response body: %v", err)
	}
	if response.StatusCode != wantStatus {
		t.Fatalf("%s %s status = %d, want %d, body = %s", request.Method, request.URL, response.StatusCode, wantStatus, string(body))
	}
	if target == nil {
		return
	}
	if err := json.Unmarshal(body, target); err != nil {
		t.Fatalf("decode response JSON: %v; body = %s", err, string(body))
	}
}
