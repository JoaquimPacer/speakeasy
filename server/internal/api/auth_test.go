package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	cryptorand "crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/joaquimpacer/speakeasy/server/internal/db"
	"github.com/joaquimpacer/speakeasy/server/internal/storage"
)

type authTestIdentity struct {
	session    authSessionResponse
	privateKey ed25519.PrivateKey
}

func TestChallengeLoginIsExpiringAndSingleUse(t *testing.T) {
	server, relay, database := newAuthTestRelay(t, Options{
		RetentionDays: 7,
		ChallengeTTL:  5 * time.Minute,
		SessionTTL:    24 * time.Hour,
	})
	identity := registerAuthTestIdentity(t, relay.URL, "challenge-alice")
	if identity.session.ExpiresAt == "" {
		t.Fatal("registration session expiresAt is empty")
	}

	challenge := requestAuthChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, http.StatusCreated)
	if len(challenge.Challenge) != loginChallengeSize {
		t.Fatalf("challenge length = %d, want %d", len(challenge.Challenge), loginChallengeSize)
	}
	signature := signLoginChallenge(identity.privateKey, challenge.Challenge)
	login := loginWithChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, challenge.ChallengeID, signature, http.StatusOK)
	if login.ExpiresAt == "" || login.BearerToken == "" {
		t.Fatalf("login session missing expiry or token: %+v", login)
	}
	if status := getStatus(t, relay.URL+"/contacts", login.BearerToken); status != http.StatusOK {
		t.Fatalf("new session status = %d, want %d", status, http.StatusOK)
	}

	loginWithChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, challenge.ChallengeID, signature, http.StatusUnauthorized)

	var consumedAt string
	if err := database.QueryRowContext(context.Background(), `SELECT consumed_at FROM auth_challenges WHERE id = ?`, challenge.ChallengeID).Scan(&consumedAt); err != nil {
		t.Fatalf("read consumed challenge: %v", err)
	}
	if consumedAt == "" {
		t.Fatal("successful challenge was not consumed")
	}

	var storedToken string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT token FROM sessions WHERE user_id = ? ORDER BY created_at ASC LIMIT 1`,
		identity.session.User.ID,
	).Scan(&storedToken); err != nil {
		t.Fatalf("read stored registration token hash: %v", err)
	}
	if storedToken != bearerTokenHash(identity.session.BearerToken) || storedToken == identity.session.BearerToken {
		t.Fatalf("stored registration token = %q, want SHA-256 hash only", storedToken)
	}

	expiresAt, err := time.Parse(time.RFC3339, login.ExpiresAt)
	if err != nil {
		t.Fatalf("parse login expiry: %v", err)
	}
	server.now = func() time.Time { return expiresAt }
	if status := getStatus(t, relay.URL+"/contacts", login.BearerToken); status != http.StatusUnauthorized {
		t.Fatalf("session at exact expiry status = %d, want %d", status, http.StatusUnauthorized)
	}
}

func TestLoginRejectsWrongProofWithoutConsumingChallengeAndRejectsExpiry(t *testing.T) {
	server, relay, _ := newAuthTestRelay(t, Options{
		RetentionDays: 7,
		ChallengeTTL:  time.Minute,
		SessionTTL:    time.Hour,
	})
	identity := registerAuthTestIdentity(t, relay.URL, "proof-alice")
	challenge := requestAuthChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, http.StatusCreated)

	wrongTranscript := append([]byte("WRONG-DOMAIN\x00"), challenge.Challenge...)
	wrongSignature := ed25519.Sign(identity.privateKey, wrongTranscript)
	loginWithChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, challenge.ChallengeID, wrongSignature, http.StatusUnauthorized)

	validSignature := signLoginChallenge(identity.privateKey, challenge.Challenge)
	loginWithChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, challenge.ChallengeID, validSignature, http.StatusOK)

	baseTime := time.Date(2026, time.August, 9, 12, 0, 0, 0, time.UTC)
	server.now = func() time.Time { return baseTime }
	expiring := requestAuthChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, http.StatusCreated)
	server.now = func() time.Time { return baseTime.Add(time.Minute) }
	loginWithChallenge(
		t,
		relay.URL,
		identity.session.User.Username,
		identity.session.Device.ID,
		expiring.ChallengeID,
		signLoginChallenge(identity.privateKey, expiring.Challenge),
		http.StatusUnauthorized,
	)
}

func TestLoginRejectsMalformedStoredSigningKeyWithoutPanicking(t *testing.T) {
	_, relay, database := newAuthTestRelay(t, Options{RetentionDays: 7})
	identity := registerAuthTestIdentity(t, relay.URL, "malformed-key-alice")
	challenge := requestAuthChallenge(
		t,
		relay.URL,
		identity.session.User.Username,
		identity.session.Device.ID,
		http.StatusCreated,
	)
	if _, err := database.ExecContext(
		context.Background(),
		`UPDATE devices SET signing_public_key = ? WHERE id = ?`,
		[]byte{0x01},
		identity.session.Device.ID,
	); err != nil {
		t.Fatalf("corrupt stored signing key: %v", err)
	}

	loginWithChallenge(
		t,
		relay.URL,
		identity.session.User.Username,
		identity.session.Device.ID,
		challenge.ChallengeID,
		signLoginChallenge(identity.privateKey, challenge.Challenge),
		http.StatusUnauthorized,
	)
}

func TestSharedSwiftSodiumLoginSignatureVector(t *testing.T) {
	publicKey, err := base64.StdEncoding.DecodeString("A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")
	if err != nil {
		t.Fatalf("decode public key: %v", err)
	}
	challenge, err := base64.StdEncoding.DecodeString("oKGio6SlpqeoqaqrrK2ur7CxsrO0tba3uLm6u7y9vr8=")
	if err != nil {
		t.Fatalf("decode challenge: %v", err)
	}
	signature, err := base64.StdEncoding.DecodeString("OL/KHudny/Wvmaw/KEoVz0jxWqfR/NkBZPtvMPzIVDfVAufkIY2h9M8V40Vdb82f880MKWvL4g5nXwIl08UWAg==")
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}

	transcript := append([]byte(loginDomain), challenge...)
	if !ed25519.Verify(ed25519.PublicKey(publicKey), transcript, signature) {
		t.Fatal("Go rejected the shared login signature produced by Swift-Sodium")
	}
}

func TestConcurrentChallengeRedemptionCreatesOneSession(t *testing.T) {
	_, relay, database := newAuthTestRelay(t, Options{RetentionDays: 7})
	identity := registerAuthTestIdentity(t, relay.URL, "concurrent-alice")
	challenge := requestAuthChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, http.StatusCreated)
	payload, err := json.Marshal(loginRequest{
		Username:          identity.session.User.Username,
		DeviceID:          identity.session.Device.ID,
		ChallengeID:       challenge.ChallengeID,
		ChallengeResponse: signLoginChallenge(identity.privateKey, challenge.Challenge),
	})
	if err != nil {
		t.Fatalf("marshal login: %v", err)
	}

	start := make(chan struct{})
	statuses := make(chan int, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			request, requestErr := http.NewRequest(http.MethodPost, relay.URL+"/auth/login", bytes.NewReader(payload))
			if requestErr != nil {
				statuses <- 0
				return
			}
			request.Header.Set("Content-Type", "application/json")
			response, requestErr := http.DefaultClient.Do(request)
			if requestErr != nil {
				statuses <- 0
				return
			}
			response.Body.Close()
			statuses <- response.StatusCode
		}()
	}
	close(start)
	wg.Wait()
	close(statuses)

	counts := map[int]int{}
	for status := range statuses {
		counts[status]++
	}
	if counts[http.StatusOK] != 1 || counts[http.StatusUnauthorized] != 1 {
		t.Fatalf("concurrent login statuses = %+v, want one 200 and one 401", counts)
	}
	var sessionCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM sessions WHERE device_id = ?`,
		identity.session.Device.ID,
	).Scan(&sessionCount); err != nil {
		t.Fatalf("count sessions: %v", err)
	}
	if sessionCount != 2 { // Registration session plus one challenge login.
		t.Fatalf("session count = %d, want 2", sessionCount)
	}
}

func TestLogoutInvalidatesAllDeviceSessionsAndChallenges(t *testing.T) {
	_, relay, database := newAuthTestRelay(t, Options{RetentionDays: 7})
	identity := registerAuthTestIdentity(t, relay.URL, "logout-alice")
	challenge := requestAuthChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, http.StatusCreated)
	second := loginWithChallenge(
		t,
		relay.URL,
		identity.session.User.Username,
		identity.session.Device.ID,
		challenge.ChallengeID,
		signLoginChallenge(identity.privateKey, challenge.Challenge),
		http.StatusOK,
	)
	outstanding := requestAuthChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, http.StatusCreated)

	request := authedRequest(t, http.MethodPost, relay.URL+"/auth/logout", identity.session.BearerToken, nil)
	doRequest(t, request, http.StatusNoContent, nil)
	if status := getStatus(t, relay.URL+"/contacts", identity.session.BearerToken); status != http.StatusUnauthorized {
		t.Fatalf("logged-out token status = %d, want %d", status, http.StatusUnauthorized)
	}
	if status := getStatus(t, relay.URL+"/contacts", second.BearerToken); status != http.StatusUnauthorized {
		t.Fatalf("other device session status = %d, want %d", status, http.StatusUnauthorized)
	}
	var challengeCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM auth_challenges WHERE id = ?`,
		outstanding.ChallengeID,
	).Scan(&challengeCount); err != nil {
		t.Fatalf("count outstanding challenges: %v", err)
	}
	if challengeCount != 0 {
		t.Fatalf("outstanding challenge count = %d, want 0", challengeCount)
	}
}

func TestLogoutRacingChallengeRedemptionLeavesDeviceRevoked(t *testing.T) {
	_, relay, database := newAuthTestRelay(t, Options{RetentionDays: 7})
	identity := registerAuthTestIdentity(t, relay.URL, "logout-race-alice")
	challenge := requestAuthChallenge(t, relay.URL, identity.session.User.Username, identity.session.Device.ID, http.StatusCreated)
	loginPayload, err := json.Marshal(loginRequest{
		Username:          identity.session.User.Username,
		DeviceID:          identity.session.Device.ID,
		ChallengeID:       challenge.ChallengeID,
		ChallengeResponse: signLoginChallenge(identity.privateKey, challenge.Challenge),
	})
	if err != nil {
		t.Fatalf("marshal login: %v", err)
	}
	loginRequest, err := http.NewRequest(http.MethodPost, relay.URL+"/auth/login", bytes.NewReader(loginPayload))
	if err != nil {
		t.Fatalf("create login request: %v", err)
	}
	loginRequest.Header.Set("Content-Type", "application/json")
	logoutRequest := authedRequest(t, http.MethodPost, relay.URL+"/auth/logout", identity.session.BearerToken, nil)

	type result struct {
		operation string
		status    int
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	var wg sync.WaitGroup
	for _, operation := range []struct {
		name    string
		request *http.Request
	}{{"login", loginRequest}, {"logout", logoutRequest}} {
		operation := operation
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			response, requestErr := http.DefaultClient.Do(operation.request)
			if requestErr != nil {
				results <- result{operation: operation.name}
				return
			}
			response.Body.Close()
			results <- result{operation: operation.name, status: response.StatusCode}
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	for outcome := range results {
		switch outcome.operation {
		case "logout":
			if outcome.status != http.StatusNoContent {
				t.Fatalf("concurrent logout status = %d, want %d", outcome.status, http.StatusNoContent)
			}
		case "login":
			if outcome.status != http.StatusOK && outcome.status != http.StatusUnauthorized {
				t.Fatalf("concurrent login status = %d, want 200 or 401", outcome.status)
			}
		}
	}

	var sessionCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM sessions WHERE device_id = ?`,
		identity.session.Device.ID,
	).Scan(&sessionCount); err != nil {
		t.Fatalf("count sessions after logout race: %v", err)
	}
	var challengeCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM auth_challenges WHERE device_id = ?`,
		identity.session.Device.ID,
	).Scan(&challengeCount); err != nil {
		t.Fatalf("count challenges after logout race: %v", err)
	}
	if sessionCount != 0 || challengeCount != 0 {
		t.Fatalf("post-race auth records = sessions %d challenges %d, want both 0", sessionCount, challengeCount)
	}
}

func TestRegistrationRateLimitUsesDirectPeerByDefault(t *testing.T) {
	_, relay, _ := newAuthTestRelay(t, Options{
		RetentionDays:          7,
		RegistrationRatePerIP:  1,
		RegistrationRateGlobal: 10,
	})
	registerAuthTestIdentity(t, relay.URL, "rate-alice")
	postJSON(t, relay.URL+"/auth/register", "", registerRequest{
		Username:            "rate-bob",
		DeviceName:          "Bob iPhone",
		EncryptionPublicKey: bytes.Repeat([]byte{0x11}, 32),
		SigningPublicKey:    bytes.Repeat([]byte{0x22}, 32),
	}, http.StatusTooManyRequests, nil)
}

func TestMalformedRegistrationConsumesScopedAllowance(t *testing.T) {
	_, relay, _ := newAuthTestRelay(t, Options{
		RetentionDays:          7,
		RegistrationRatePerIP:  1,
		RegistrationRateGlobal: 10,
	})
	request, err := http.NewRequest(
		http.MethodPost,
		relay.URL+"/auth/register",
		strings.NewReader("{"),
	)
	if err != nil {
		t.Fatalf("create malformed request: %v", err)
	}
	request.Header.Set("Content-Type", "application/json")
	doRequest(t, request, http.StatusBadRequest, nil)

	postJSON(t, relay.URL+"/auth/register", "", registerRequest{
		Username:            "rate-after-malformed",
		DeviceName:          "Rate iPhone",
		EncryptionPublicKey: bytes.Repeat([]byte{0x11}, 32),
		SigningPublicKey:    bytes.Repeat([]byte{0x22}, 32),
	}, http.StatusTooManyRequests, nil)
}

func newAuthTestRelay(t *testing.T, options Options) (*Server, *httptest.Server, *sql.DB) {
	t.Helper()
	database, err := db.Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })
	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}
	server := NewWithOptions(database, blobStore, options)
	relay := httptest.NewServer(server.Handler())
	t.Cleanup(relay.Close)
	return server, relay, database
}

func registerAuthTestIdentity(t *testing.T, baseURL string, username string) authTestIdentity {
	t.Helper()
	publicKey, privateKey, err := ed25519.GenerateKey(cryptorand.Reader)
	if err != nil {
		t.Fatalf("generate signing key: %v", err)
	}
	var session authSessionResponse
	postJSON(t, baseURL+"/auth/register", "", registerRequest{
		Username:            username,
		DeviceName:          username + " iPhone",
		EncryptionPublicKey: bytes.Repeat([]byte{0x42}, 32),
		SigningPublicKey:    publicKey,
	}, http.StatusCreated, &session)
	return authTestIdentity{session: session, privateKey: privateKey}
}

func requestAuthChallenge(t *testing.T, baseURL string, username string, deviceID string, wantStatus int) authChallengeResponse {
	t.Helper()
	var challenge authChallengeResponse
	var target any
	if wantStatus == http.StatusCreated {
		target = &challenge
	}
	postJSON(t, baseURL+"/auth/challenge", "", authChallengeRequest{
		Username: username,
		DeviceID: deviceID,
	}, wantStatus, target)
	return challenge
}

func loginWithChallenge(t *testing.T, baseURL string, username string, deviceID string, challengeID string, signature []byte, wantStatus int) authSessionResponse {
	t.Helper()
	var session authSessionResponse
	var target any
	if wantStatus == http.StatusOK {
		target = &session
	}
	postJSON(t, baseURL+"/auth/login", "", loginRequest{
		Username:          username,
		DeviceID:          deviceID,
		ChallengeID:       challengeID,
		ChallengeResponse: signature,
	}, wantStatus, target)
	return session
}

func signLoginChallenge(privateKey ed25519.PrivateKey, challenge []byte) []byte {
	transcript := append([]byte(loginDomain), challenge...)
	return ed25519.Sign(privateKey, transcript)
}
