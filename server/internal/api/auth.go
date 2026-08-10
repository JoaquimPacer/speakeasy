package api

import (
	"context"
	// crypto/ed25519 implements RFC 8032 detached-signature verification and is
	// wire-compatible with libsodium's crypto_sign signatures. Keeping relay
	// verification in the standard library preserves the static CGO-free build.
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"time"
)

const (
	loginChallengeSize = 32
	loginDomain        = "KITHRA-LOGIN-CHALLENGE-v1\x00"
)

func bearerTokenHash(token string) string {
	digest := sha256.Sum256([]byte(token))
	return hex.EncodeToString(digest[:])
}

type authChallengeRequest struct {
	Username string `json:"username"`
	DeviceID string `json:"deviceID"`
}

type authChallengeResponse struct {
	ChallengeID string `json:"challengeID"`
	Challenge   []byte `json:"challenge"`
	ExpiresAt   string `json:"expiresAt"`
}

type loginRequest struct {
	Username          string `json:"username"`
	DeviceID          string `json:"deviceID"`
	ChallengeID       string `json:"challengeID"`
	ChallengeResponse []byte `json:"challengeResponse"`
}

func (s *Server) handleAuthChallenge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	clientIP := s.clientIP(r)
	if !s.allowScopedThenGlobal(w, s.authIPLimiter, clientIP, s.authGlobalLimiter) {
		return
	}

	var req authChallengeRequest
	if !readJSON(w, r, &req) {
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	req.DeviceID = normalizeID(req.DeviceID)
	if req.Username == "" || req.DeviceID == "" {
		http.Error(w, "username and deviceID are required", http.StatusBadRequest)
		return
	}
	if !isNonzeroUUID(req.DeviceID) {
		http.Error(w, "deviceID must be a nonzero UUID", http.StatusBadRequest)
		return
	}

	var exists int
	err := s.db.QueryRowContext(
		r.Context(),
		`SELECT 1
		   FROM devices d
		   JOIN users u ON u.id = d.user_id
		  WHERE d.id = ? AND u.username = ?`,
		req.DeviceID,
		req.Username,
	).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "invalid login identity", http.StatusUnauthorized)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	challenge := make([]byte, loginChallengeSize)
	if _, err := rand.Read(challenge); err != nil {
		http.Error(w, "could not generate challenge", http.StatusInternalServerError)
		return
	}
	now := s.now().UTC().Truncate(time.Second)
	if err := s.pruneExpiredAuthRecords(r.Context(), now); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	challengeID := mustID()
	expiresAt := now.Add(s.options.ChallengeTTL).Format(time.RFC3339)
	if _, err := s.db.ExecContext(
		r.Context(),
		`INSERT INTO auth_challenges(id, device_id, challenge, expires_at, created_at)
		 VALUES (?, ?, ?, ?, ?)`,
		challengeID,
		req.DeviceID,
		challenge,
		expiresAt,
		now.Format(time.RFC3339),
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, authChallengeResponse{
		ChallengeID: challengeID,
		Challenge:   challenge,
		ExpiresAt:   expiresAt,
	})
}

func (s *Server) pruneExpiredAuthRecords(ctx context.Context, now time.Time) error {
	nowText := now.Format(time.RFC3339)
	if _, err := s.db.ExecContext(
		ctx,
		`DELETE FROM sessions WHERE expires_at <= ?`,
		nowText,
	); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(
		ctx,
		`DELETE FROM auth_challenges WHERE expires_at <= ? OR consumed_at IS NOT NULL`,
		nowText,
	); err != nil {
		return err
	}
	return nil
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	clientIP := s.clientIP(r)
	if !s.allowScopedThenGlobal(w, s.authIPLimiter, clientIP, s.authGlobalLimiter) {
		return
	}

	var req loginRequest
	if !readJSON(w, r, &req) {
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	req.DeviceID = normalizeID(req.DeviceID)
	req.ChallengeID = normalizeID(req.ChallengeID)
	if req.Username == "" || req.DeviceID == "" || req.ChallengeID == "" {
		http.Error(w, "username, deviceID, and challengeID are required", http.StatusBadRequest)
		return
	}
	if !isNonzeroUUID(req.DeviceID) || !isNonzeroUUID(req.ChallengeID) {
		http.Error(w, "deviceID and challengeID must be nonzero UUIDs", http.StatusBadRequest)
		return
	}
	if len(req.ChallengeResponse) != ed25519.SignatureSize {
		http.Error(w, "invalid login proof", http.StatusUnauthorized)
		return
	}

	now := s.now().UTC().Truncate(time.Second)
	nowText := now.Format(time.RFC3339)
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()

	identity, challenge, err := lookupLoginIdentity(r.Context(), tx, req, nowText)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "invalid or expired login challenge", http.StatusUnauthorized)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	transcript := make([]byte, 0, len(loginDomain)+len(challenge))
	transcript = append(transcript, loginDomain...)
	transcript = append(transcript, challenge...)
	if len(identity.device.SigningPublicKey) != ed25519.PublicKeySize {
		http.Error(w, "invalid login proof", http.StatusUnauthorized)
		return
	}
	if !ed25519.Verify(ed25519.PublicKey(identity.device.SigningPublicKey), transcript, req.ChallengeResponse) {
		http.Error(w, "invalid login proof", http.StatusUnauthorized)
		return
	}

	result, err := tx.ExecContext(
		r.Context(),
		`UPDATE auth_challenges
		    SET consumed_at = ?
		  WHERE id = ? AND device_id = ? AND consumed_at IS NULL AND expires_at > ?`,
		nowText,
		req.ChallengeID,
		req.DeviceID,
		nowText,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	consumed, err := result.RowsAffected()
	if err != nil || consumed != 1 {
		http.Error(w, "invalid or expired login challenge", http.StatusUnauthorized)
		return
	}

	token := mustToken()
	expiresAt := now.Add(s.options.SessionTTL).Format(time.RFC3339)
	if _, err := tx.ExecContext(
		r.Context(),
		`INSERT INTO sessions(token, user_id, device_id, expires_at, created_at)
		 VALUES (?, ?, ?, ?, ?)`,
		bearerTokenHash(token),
		identity.user.ID,
		identity.device.ID,
		expiresAt,
		nowText,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if _, err := tx.ExecContext(
		r.Context(),
		`UPDATE devices SET last_seen_at = ?, updated_at = ? WHERE id = ?`,
		nowText,
		nowText,
		identity.device.ID,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := tx.Commit(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	identity.device.LastSeenAt = nowText
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, authSessionResponse{
		User:        identity.user,
		Device:      identity.device,
		BearerToken: token,
		ExpiresAt:   expiresAt,
	})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(r.Context(), `DELETE FROM sessions WHERE device_id = ?`, principal.deviceID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if _, err := tx.ExecContext(r.Context(), `DELETE FROM auth_challenges WHERE device_id = ?`, principal.deviceID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := tx.Commit(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type loginIdentity struct {
	user   userResponse
	device deviceResponse
}

func lookupLoginIdentity(ctx context.Context, tx *sql.Tx, req loginRequest, nowText string) (loginIdentity, []byte, error) {
	var identity loginIdentity
	var challenge []byte
	err := tx.QueryRowContext(
		ctx,
		`SELECT u.id, u.username, u.created_at,
		        d.id, d.user_id, d.name, d.encryption_public_key, d.signing_public_key,
		        d.created_at, COALESCE(d.last_seen_at, ''), ac.challenge
		   FROM auth_challenges ac
		   JOIN devices d ON d.id = ac.device_id
		   JOIN users u ON u.id = d.user_id
		  WHERE ac.id = ? AND ac.device_id = ? AND u.username = ?
		    AND ac.consumed_at IS NULL AND ac.expires_at > ?`,
		req.ChallengeID,
		req.DeviceID,
		req.Username,
		nowText,
	).Scan(
		&identity.user.ID,
		&identity.user.Username,
		&identity.user.CreatedAt,
		&identity.device.ID,
		&identity.device.UserID,
		&identity.device.Name,
		&identity.device.EncryptionPublicKey,
		&identity.device.SigningPublicKey,
		&identity.device.CreatedAt,
		&identity.device.LastSeenAt,
		&challenge,
	)
	return identity, challenge, err
}
