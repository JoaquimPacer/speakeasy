package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/joaquimpacer/speakeasy/server/internal/storage"
)

type Server struct {
	db            *sql.DB
	store         storage.Store
	startedAt     time.Time
	retentionDays int
	options       Options
	now           func() time.Time

	blobMutationMu sync.Mutex
	abuseWriteMu   sync.Mutex

	registrationIPLimiter     *fixedWindowLimiter
	registrationGlobalLimiter *fixedWindowLimiter
	authIPLimiter             *fixedWindowLimiter
	authGlobalLimiter         *fixedWindowLimiter
	uploadAccountLimiter      *fixedWindowLimiter
	inviteAccountLimiter      *fixedWindowLimiter
	reportAccountLimiter      *fixedWindowLimiter
}

func New(db *sql.DB, store storage.Store, retentionDays int) *Server {
	return NewWithOptions(db, store, Options{RetentionDays: retentionDays})
}

func NewWithOptions(db *sql.DB, store storage.Store, options Options) *Server {
	options = normalizeOptions(options)
	server := &Server{
		db:            db,
		store:         store,
		startedAt:     time.Now().UTC(),
		retentionDays: options.RetentionDays,
		options:       options,
		now:           time.Now,
	}
	server.registrationIPLimiter = newFixedWindowLimiter(options.RegistrationRatePerIP, options.RegistrationRateWindow)
	server.registrationGlobalLimiter = newFixedWindowLimiter(options.RegistrationRateGlobal, options.RegistrationRateWindow)
	server.authIPLimiter = newFixedWindowLimiter(options.AuthRatePerIP, options.AuthRateWindow)
	server.authGlobalLimiter = newFixedWindowLimiter(options.AuthRateGlobal, options.AuthRateWindow)
	server.uploadAccountLimiter = newFixedWindowLimiter(options.UploadRatePerAccount, options.UploadRateWindow)
	server.inviteAccountLimiter = newFixedWindowLimiter(options.InviteRatePerAccount, options.InviteRateWindow)
	server.reportAccountLimiter = newFixedWindowLimiter(options.ReportRatePerAccount, options.ReportRateWindow)
	return server
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/auth/register", s.handleRegister)
	mux.HandleFunc("/auth/challenge", s.handleAuthChallenge)
	mux.HandleFunc("/auth/login", s.handleLogin)
	mux.HandleFunc("/auth/logout", s.handleLogout)
	mux.HandleFunc("/account", s.handleAccount)
	mux.HandleFunc("/contacts/invite", s.handleCreateInvite)
	mux.HandleFunc("/contacts/accept", s.handleAcceptInvite)
	mux.HandleFunc("/contacts", s.handleContacts)
	mux.HandleFunc("/contacts/", s.handleContactByID)
	mux.HandleFunc("/messages", s.handleMessages)
	mux.HandleFunc("/messages/", s.handleMessageByID)
	mux.HandleFunc("/blocks", s.handleBlocks)
	mux.HandleFunc("/reports", s.handleReports)
	return mux
}

type principal struct {
	userID   string
	deviceID string
}

type healthResponse struct {
	Status                   string            `json:"status"`
	Service                  string            `json:"service"`
	Time                     string            `json:"time"`
	UptimeSeconds            int64             `json:"uptimeSeconds"`
	UndeliveredRetentionDays int               `json:"undeliveredRetentionDays"`
	Checks                   map[string]string `json:"checks"`
}

type userResponse struct {
	ID        string `json:"id"`
	Username  string `json:"username"`
	CreatedAt string `json:"createdAt"`
}

type deviceResponse struct {
	ID                  string `json:"id"`
	UserID              string `json:"userID"`
	Name                string `json:"name,omitempty"`
	EncryptionPublicKey []byte `json:"encryptionPublicKey"`
	SigningPublicKey    []byte `json:"signingPublicKey"`
	CreatedAt           string `json:"createdAt"`
	LastSeenAt          string `json:"lastSeenAt,omitempty"`
}

type authSessionResponse struct {
	User        userResponse   `json:"user"`
	Device      deviceResponse `json:"device"`
	BearerToken string         `json:"bearerToken"`
	ExpiresAt   string         `json:"expiresAt,omitempty"`
}

type registerRequest struct {
	Username            string `json:"username"`
	DeviceName          string `json:"deviceName"`
	EncryptionPublicKey []byte `json:"encryptionPublicKey"`
	SigningPublicKey    []byte `json:"signingPublicKey"`
}

const (
	x25519PublicKeySize            = 32
	ed25519PublicKeySize           = 32
	identityDigestSize             = 32
	xChaCha20Poly1305NonceSize     = 24
	ciphertextHashSize             = 32
	sealedContentKeySize           = 80
	ed25519SignatureSize           = 64
	maxUsernameUTF8Bytes           = 128
	maxUploadMetadataBytes         = 64 << 10
	maxAuthenticatedEnvelopeBytes  = 48 << 10
	maxEnvelopeMIMETypeUTF8Bytes   = 255
	maxKeyFingerprintUTF8Bytes     = 256
	maxThumbnailPathUTF8Bytes      = 2 << 10
	maxReportReasonUTF8Bytes       = 128
	maxReportDetailsUTF8Bytes      = 4 << 10
	authenticatedEnvelopeV2        = 2
	xChaCha20Poly1305Algorithm     = "XChaCha20-Poly1305"
	sealedContentKeyAlgorithm      = "crypto_box_seal"
	ed25519AuthenticationAlgorithm = "Ed25519"
	authenticatedCreatedAtLayout   = "2006-01-02T15:04:05Z"
)

func (r *registerRequest) UnmarshalJSON(data []byte) error {
	if !utf8.Valid(data) {
		return errors.New("registration JSON must be valid UTF-8")
	}

	type wireRegisterRequest registerRequest
	var decoded wireRegisterRequest
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&decoded); err != nil {
		return err
	}
	*r = registerRequest(decoded)
	return nil
}

type contactResponse struct {
	UserID              string `json:"userID"`
	ContactID           string `json:"contactID"`
	DeviceID            string `json:"deviceID"`
	Username            string `json:"username"`
	Nickname            string `json:"nickname,omitempty"`
	EncryptionPublicKey []byte `json:"encryptionPublicKey"`
	SigningPublicKey    []byte `json:"signingPublicKey"`
	CreatedAt           string `json:"createdAt"`
}

type inviteResponse struct {
	InviteID  string `json:"inviteID"`
	Code      string `json:"code"`
	ExpiresAt string `json:"expiresAt"`
}

type acceptInviteRequest struct {
	Code string `json:"code"`
}

type uploadMetadata struct {
	RecipientID       string          `json:"recipientID"`
	RecipientDeviceID string          `json:"recipientDeviceID"`
	Envelope          json.RawMessage `json:"envelope"`
	BlobSize          int64           `json:"blobSize"`
	DurationMs        int64           `json:"durationMs"`
}

type authenticatedMessageEnvelope struct {
	Version                 int                              `json:"version"`
	ClientMessageID         string                           `json:"clientMessageID"`
	SenderDeviceID          string                           `json:"senderDeviceID"`
	RecipientDeviceID       string                           `json:"recipientDeviceID"`
	SenderIdentityDigest    []byte                           `json:"senderIdentityDigest"`
	RecipientIdentityDigest []byte                           `json:"recipientIdentityDigest"`
	AuthenticationAlgorithm string                           `json:"authenticationAlgorithm"`
	Signature               []byte                           `json:"signature"`
	Media                   authenticatedEnvelopeMedia       `json:"media"`
	ContentKey              authenticatedEnvelopeContentKey  `json:"contentKey"`
	SenderContentKey        *authenticatedEnvelopeContentKey `json:"senderContentKey"`
	CreatedAt               string                           `json:"createdAt"`
}

type authenticatedEnvelopeMedia struct {
	Algorithm       string                          `json:"algorithm"`
	Nonce           []byte                          `json:"nonce"`
	CiphertextHash  []byte                          `json:"ciphertextHash"`
	MIMEType        string                          `json:"mimeType"`
	DurationSeconds *float64                        `json:"durationSeconds"`
	Thumbnail       *authenticatedEnvelopeThumbnail `json:"thumbnail"`
}

type authenticatedEnvelopeThumbnail struct {
	Algorithm         string `json:"algorithm"`
	Nonce             []byte `json:"nonce"`
	EncryptedBlobPath string `json:"encryptedBlobPath"`
	CiphertextHash    []byte `json:"ciphertextHash"`
}

type authenticatedEnvelopeContentKey struct {
	Algorithm                     string  `json:"algorithm"`
	EncryptedContentKey           []byte  `json:"encryptedContentKey"`
	RecipientPublicKeyFingerprint *string `json:"recipientPublicKeyFingerprint"`
}

type messageResponse struct {
	ID                string          `json:"id"`
	SenderID          string          `json:"senderID"`
	SenderDeviceID    string          `json:"senderDeviceID"`
	RecipientID       string          `json:"recipientID"`
	RecipientDeviceID string          `json:"recipientDeviceID,omitempty"`
	Envelope          json.RawMessage `json:"envelope"`
	EncryptedBlobPath string          `json:"encryptedBlobPath,omitempty"`
	BlobSize          int64           `json:"blobSize"`
	Status            string          `json:"status"`
	DeliveredAt       string          `json:"deliveredAt,omitempty"`
	BlobDeletedAt     string          `json:"blobDeletedAt,omitempty"`
	CreatedAt         string          `json:"createdAt"`
	ExpiresAt         string          `json:"expiresAt"`
}

type deliveredResponse struct {
	MessageID   string `json:"messageID"`
	Status      string `json:"status"`
	BlobDeleted bool   `json:"blobDeleted"`
}

type updateStatusRequest struct {
	Status string `json:"status"`
}

type blockRequest struct {
	BlockedUserID string `json:"blockedUserID"`
}

type reportRequest struct {
	ReportedUserID string `json:"reportedUserID"`
	MessageID      string `json:"messageID"`
	Reason         string `json:"reason"`
	Details        string `json:"details"`
}

func (r *reportRequest) UnmarshalJSON(data []byte) error {
	if !utf8.Valid(data) {
		return errors.New("report JSON must be valid UTF-8")
	}
	type wireReportRequest reportRequest
	var decoded wireReportRequest
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&decoded); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("report JSON must contain exactly one value")
	}
	*r = reportRequest(decoded)
	return nil
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	status := "ok"
	code := http.StatusOK
	checks := map[string]string{
		"database": "ok",
		"storage":  "ok",
	}

	if s.db == nil {
		status = "unhealthy"
		code = http.StatusServiceUnavailable
		checks["database"] = "missing"
	} else if err := s.db.PingContext(ctx); err != nil {
		status = "unhealthy"
		code = http.StatusServiceUnavailable
		checks["database"] = err.Error()
	}

	if s.store == nil {
		status = "unhealthy"
		code = http.StatusServiceUnavailable
		checks["storage"] = "missing"
	} else if err := s.store.Ready(ctx); err != nil {
		status = "unhealthy"
		code = http.StatusServiceUnavailable
		checks["storage"] = err.Error()
	}

	writeJSON(w, code, healthResponse{
		Status:                   status,
		Service:                  "speakeasy-relay",
		Time:                     time.Now().UTC().Format(time.RFC3339),
		UptimeSeconds:            int64(time.Since(s.startedAt).Seconds()),
		UndeliveredRetentionDays: s.retentionDays,
		Checks:                   checks,
	})
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	clientIP := s.clientIP(r)
	if !s.allowScopedThenGlobal(
		w,
		s.registrationIPLimiter,
		clientIP,
		s.registrationGlobalLimiter,
	) {
		return
	}
	var req registerRequest
	if !readJSON(w, r, &req) {
		return
	}

	req.Username = strings.TrimSpace(req.Username)
	req.DeviceName = strings.TrimSpace(req.DeviceName)
	if err := validateUsername(req.Username); err != nil {
		http.Error(w, "invalid username: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(req.EncryptionPublicKey) == 0 || len(req.SigningPublicKey) == 0 {
		http.Error(w, "encryptionPublicKey and signingPublicKey are required", http.StatusBadRequest)
		return
	}
	if len(req.EncryptionPublicKey) != x25519PublicKeySize || len(req.SigningPublicKey) != ed25519PublicKeySize {
		http.Error(w, "encryptionPublicKey and signingPublicKey must each decode to exactly 32 bytes", http.StatusBadRequest)
		return
	}
	nowTime := s.now().UTC().Truncate(time.Second)
	now := nowTime.Format(time.RFC3339)
	expiresAt := nowTime.Add(s.options.SessionTTL).Format(time.RFC3339)
	userID := mustID()
	deviceID := mustID()
	token := mustToken()

	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(
		r.Context(),
		`INSERT INTO users(id, username, created_at, updated_at) VALUES (?, ?, ?, ?)`,
		userID,
		req.Username,
		now,
		now,
	); err != nil {
		http.Error(w, "username is already taken or invalid", http.StatusConflict)
		return
	}

	if _, err := tx.ExecContext(
		r.Context(),
		`INSERT INTO devices(id, user_id, name, encryption_public_key, signing_public_key, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		deviceID,
		userID,
		req.DeviceName,
		req.EncryptionPublicKey,
		req.SigningPublicKey,
		now,
		now,
	); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if _, err := tx.ExecContext(
		r.Context(),
		`INSERT INTO sessions(token, user_id, device_id, expires_at, created_at) VALUES (?, ?, ?, ?, ?)`,
		bearerTokenHash(token),
		userID,
		deviceID,
		expiresAt,
		now,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if err := tx.Commit(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusCreated, authSessionResponse{
		User: userResponse{
			ID:        userID,
			Username:  req.Username,
			CreatedAt: now,
		},
		Device: deviceResponse{
			ID:                  deviceID,
			UserID:              userID,
			Name:                req.DeviceName,
			EncryptionPublicKey: req.EncryptionPublicKey,
			SigningPublicKey:    req.SigningPublicKey,
			CreatedAt:           now,
		},
		BearerToken: token,
		ExpiresAt:   expiresAt,
	})
}

func (s *Server) handleAccount(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/account" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodDelete {
		methodNotAllowed(w, http.MethodDelete)
		return
	}

	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}

	s.blobMutationMu.Lock()
	defer s.blobMutationMu.Unlock()

	rows, err := s.db.QueryContext(
		r.Context(),
		`SELECT encrypted_blob_path
		   FROM messages
		  WHERE (sender_user_id = ? OR recipient_user_id = ?)
		    AND encrypted_blob_path <> ''`,
		principal.userID,
		principal.userID,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var blobPaths []string
	for rows.Next() {
		var blobPath string
		if err := rows.Scan(&blobPath); err != nil {
			rows.Close()
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		blobPaths = append(blobPaths, blobPath)
	}
	if err := rows.Close(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := rows.Err(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	for _, blobPath := range blobPaths {
		if err := s.store.Delete(r.Context(), blobPath); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}

	if _, err := s.db.ExecContext(r.Context(), `DELETE FROM users WHERE id = ?`, principal.userID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleCreateInvite(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}

	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if !s.allowRate(w, s.inviteAccountLimiter, principal.userID) {
		return
	}

	s.abuseWriteMu.Lock()
	defer s.abuseWriteMu.Unlock()

	inviteID := mustID()
	code := mustInviteCode()
	nowTime := s.now().UTC().Truncate(time.Second)
	expiresAt := nowTime.Add(7 * 24 * time.Hour).Format(time.RFC3339)
	now := nowTime.Format(time.RFC3339)

	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(
		r.Context(),
		`UPDATE invites SET status = 'expired' WHERE status = 'pending' AND expires_at <= ?`,
		now,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var accountRecords int
	var outstanding int
	if err := tx.QueryRowContext(
		r.Context(),
		`SELECT COUNT(*), COALESCE(SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END), 0)
		   FROM invites WHERE inviter_user_id = ?`,
		principal.userID,
	).Scan(&accountRecords, &outstanding); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if outstanding >= s.options.MaxOutstandingInvitesPerAccount {
		http.Error(w, "outstanding invite limit reached", http.StatusTooManyRequests)
		return
	}
	if accountRecords >= s.options.MaxInviteRecordsPerAccount {
		http.Error(w, "account invite record capacity reached", http.StatusInsufficientStorage)
		return
	}
	var totalRecords int
	if err := tx.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM invites`).Scan(&totalRecords); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if totalRecords >= s.options.MaxInviteRecordsTotal {
		http.Error(w, "relay invite record capacity reached", http.StatusInsufficientStorage)
		return
	}

	_, err = tx.ExecContext(
		r.Context(),
		`INSERT INTO invites(id, code, inviter_user_id, inviter_device_id, expires_at, created_at)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		inviteID,
		code,
		principal.userID,
		principal.deviceID,
		expiresAt,
		now,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := tx.Commit(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusCreated, inviteResponse{
		InviteID:  inviteID,
		Code:      code,
		ExpiresAt: expiresAt,
	})
}

func (s *Server) handleAcceptInvite(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}

	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}

	var req acceptInviteRequest
	if !readJSON(w, r, &req) {
		return
	}
	code := strings.TrimSpace(strings.ToUpper(req.Code))
	if code == "" {
		http.Error(w, "code is required", http.StatusBadRequest)
		return
	}

	now := s.now().UTC().Format(time.RFC3339)
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()

	claim, err := tx.ExecContext(
		r.Context(),
		`UPDATE invites
		    SET status = 'accepted', accepted_by_user_id = ?, accepted_at = ?
		  WHERE code = ? AND status = 'pending' AND expires_at > ?
		    AND inviter_user_id <> ?`,
		principal.userID,
		now,
		code,
		now,
		principal.userID,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	claimed, err := claim.RowsAffected()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if claimed != 1 {
		if claimed != 0 {
			http.Error(w, "invite claim affected an unexpected number of rows", http.StatusInternalServerError)
			return
		}

		var pendingInviterID string
		lookupErr := tx.QueryRowContext(
			r.Context(),
			`SELECT inviter_user_id FROM invites
			  WHERE code = ? AND status = 'pending' AND expires_at > ?`,
			code,
			now,
		).Scan(&pendingInviterID)
		if lookupErr == nil && pendingInviterID == principal.userID {
			http.Error(w, "cannot accept your own invite", http.StatusBadRequest)
			return
		}
		if lookupErr != nil && !errors.Is(lookupErr, sql.ErrNoRows) {
			http.Error(w, lookupErr.Error(), http.StatusInternalServerError)
			return
		}
		http.Error(w, "invite not found or expired", http.StatusNotFound)
		return
	}

	var inviterID string
	if err := tx.QueryRowContext(
		r.Context(),
		`SELECT inviter_user_id FROM invites
		  WHERE code = ? AND status = 'accepted' AND accepted_by_user_id = ?`,
		code,
		principal.userID,
	).Scan(&inviterID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	for _, pair := range [][2]string{{principal.userID, inviterID}, {inviterID, principal.userID}} {
		if _, err := tx.ExecContext(
			r.Context(),
			`INSERT OR IGNORE INTO contacts(user_id, contact_user_id, created_at) VALUES (?, ?, ?)`,
			pair[0],
			pair[1],
			now,
		); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}

	if err := tx.Commit(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	contact, err := s.lookupContact(r.Context(), principal.userID, inviterID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, contact)
}

func (s *Server) handleContacts(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/contacts" {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}

	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}

	rows, err := s.db.QueryContext(
		r.Context(),
		`SELECT c.user_id, c.contact_user_id, u.username, COALESCE(c.nickname, ''),
		        d.id, d.encryption_public_key, d.signing_public_key, c.created_at
		   FROM contacts c
		   JOIN users u ON u.id = c.contact_user_id
		   JOIN devices d ON d.user_id = c.contact_user_id
		  WHERE c.user_id = ?
		  ORDER BY c.created_at DESC`,
		principal.userID,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	contacts := []contactResponse{}
	for rows.Next() {
		var contact contactResponse
		if err := rows.Scan(
			&contact.UserID,
			&contact.ContactID,
			&contact.Username,
			&contact.Nickname,
			&contact.DeviceID,
			&contact.EncryptionPublicKey,
			&contact.SigningPublicKey,
			&contact.CreatedAt,
		); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		contacts = append(contacts, contact)
	}

	writeJSON(w, http.StatusOK, contacts)
}

func (s *Server) handleContactByID(w http.ResponseWriter, r *http.Request) {
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, "/contacts/"), "/")
	if rest == "" || strings.Contains(rest, "/") {
		http.NotFound(w, r)
		return
	}

	contactID := normalizeID(rest)
	if contactID == "" {
		http.Error(w, "contactID is invalid", http.StatusBadRequest)
		return
	}

	switch r.Method {
	case http.MethodDelete:
		s.deleteContact(w, r, contactID)
	default:
		methodNotAllowed(w, http.MethodDelete)
	}
}

func (s *Server) deleteContact(w http.ResponseWriter, r *http.Request, contactID string) {
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if contactID == principal.userID {
		http.Error(w, "contactID must be another user", http.StatusBadRequest)
		return
	}

	if _, err := s.db.ExecContext(
		r.Context(),
		`DELETE FROM contacts WHERE user_id = ? AND contact_user_id = ?`,
		principal.userID,
		contactID,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMessages(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/messages" {
		http.NotFound(w, r)
		return
	}

	switch r.Method {
	case http.MethodGet:
		s.listMessages(w, r)
	case http.MethodPost:
		s.uploadMessage(w, r)
	default:
		methodNotAllowed(w, http.MethodGet, http.MethodPost)
	}
}

func (s *Server) listMessages(w http.ResponseWriter, r *http.Request) {
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}

	rows, err := s.db.QueryContext(
		r.Context(),
		`SELECT id, sender_user_id, sender_device_id, recipient_user_id,
		        COALESCE(recipient_device_id, ''), envelope_json, encrypted_blob_path,
		        blob_size, status, COALESCE(delivered_at, ''), COALESCE(blob_deleted_at, ''),
		        created_at, expires_at
		   FROM messages
		  WHERE (sender_user_id = ? OR recipient_user_id = ?)
		    AND status NOT IN ('deleted', 'expired')
		  ORDER BY created_at DESC`,
		principal.userID,
		principal.userID,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	messages := []messageResponse{}
	for rows.Next() {
		message, err := scanMessage(rows)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		messages = append(messages, message)
	}

	writeJSON(w, http.StatusOK, messages)
}

func (s *Server) uploadMessage(w http.ResponseWriter, r *http.Request) {
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if !s.allowRate(w, s.uploadAccountLimiter, principal.userID) {
		return
	}

	maxRequestBytes := s.options.MaxUploadBytes + maxUploadMetadataBytes + (1 << 20)
	if r.ContentLength > maxRequestBytes {
		http.Error(w, "upload is too large", http.StatusRequestEntityTooLarge)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			http.Error(w, "upload is too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "invalid multipart upload", http.StatusBadRequest)
		return
	}
	if r.MultipartForm != nil {
		defer r.MultipartForm.RemoveAll()
	}

	metadataPart := r.FormValue("metadata")
	if metadataPart == "" {
		http.Error(w, "metadata part is required", http.StatusBadRequest)
		return
	}
	if len(metadataPart) > maxUploadMetadataBytes {
		http.Error(w, "metadata part is too large", http.StatusRequestEntityTooLarge)
		return
	}
	if !utf8.ValidString(metadataPart) {
		http.Error(w, "invalid metadata JSON", http.StatusBadRequest)
		return
	}

	var metadata uploadMetadata
	metadataDecoder := json.NewDecoder(strings.NewReader(metadataPart))
	metadataDecoder.DisallowUnknownFields()
	if err := metadataDecoder.Decode(&metadata); err != nil {
		http.Error(w, "invalid metadata JSON", http.StatusBadRequest)
		return
	}
	if err := metadataDecoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		http.Error(w, "invalid metadata JSON", http.StatusBadRequest)
		return
	}
	metadata.RecipientID = normalizeID(metadata.RecipientID)
	metadata.RecipientDeviceID = normalizeID(metadata.RecipientDeviceID)
	if metadata.RecipientID == "" || metadata.RecipientDeviceID == "" || len(metadata.Envelope) == 0 {
		http.Error(w, "recipientID, recipientDeviceID, and envelope are required", http.StatusBadRequest)
		return
	}
	if err := validateAuthenticatedEnvelope(metadata.Envelope, principal.deviceID, metadata.RecipientDeviceID); err != nil {
		http.Error(w, "invalid envelope: "+err.Error(), http.StatusBadRequest)
		return
	}
	if metadata.RecipientID == principal.userID {
		http.Error(w, "recipientID must be another user", http.StatusBadRequest)
		return
	}

	if isContact, err := s.hasContact(r.Context(), principal.userID, metadata.RecipientID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	} else if !isContact {
		http.Error(w, "recipient is not a contact", http.StatusForbidden)
		return
	}

	if belongs, err := s.deviceBelongsToUser(r.Context(), metadata.RecipientDeviceID, metadata.RecipientID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	} else if !belongs {
		http.Error(w, "recipientDeviceID does not belong to recipientID", http.StatusBadRequest)
		return
	}

	file, fileHeader, err := r.FormFile("blob")
	if err != nil {
		http.Error(w, "blob part is required", http.StatusBadRequest)
		return
	}
	defer file.Close()
	if fileHeader.Size <= 0 {
		http.Error(w, "blob must not be empty", http.StatusBadRequest)
		return
	}
	if fileHeader.Size > s.options.MaxUploadBytes {
		http.Error(w, "blob is too large", http.StatusRequestEntityTooLarge)
		return
	}
	if metadata.BlobSize != fileHeader.Size {
		http.Error(w, "blobSize must match the uploaded ciphertext size", http.StatusBadRequest)
		return
	}

	if blocked, err := s.isBlocked(r.Context(), principal.userID, metadata.RecipientID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	} else if blocked {
		http.Error(w, "recipient has blocked sender", http.StatusForbidden)
		return
	}

	s.blobMutationMu.Lock()
	defer s.blobMutationMu.Unlock()
	if err := s.checkPendingQuota(r.Context(), principal.userID, metadata.RecipientID, fileHeader.Size); err != nil {
		var quotaErr *pendingQuotaError
		if errors.As(err, &quotaErr) {
			http.Error(w, quotaErr.Error(), http.StatusInsufficientStorage)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	messageID := mustID()
	blobKey := "messages/" + messageID + ".blob"
	now := s.now().UTC().Truncate(time.Second)
	expiresAt := now.Add(time.Duration(s.retentionDays) * 24 * time.Hour).Format(time.RFC3339)
	nowText := now.Format(time.RFC3339)
	if _, err := s.db.ExecContext(
		r.Context(),
		`INSERT INTO pending_blob_writes(
			blob_path, sender_user_id, recipient_user_id, blob_size, state, created_at
		 ) VALUES (?, ?, ?, ?, 'pending', ?)`,
		blobKey,
		principal.userID,
		metadata.RecipientID,
		metadata.BlobSize,
		nowText,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := s.store.Write(r.Context(), blobKey, file); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if size, err := s.blobSize(blobKey); err != nil || size != metadata.BlobSize {
		verificationErr := err
		if verificationErr == nil {
			verificationErr = fmt.Errorf("actual size %d does not match declared size %d", size, metadata.BlobSize)
		}
		http.Error(w, "verify uploaded ciphertext: "+verificationErr.Error(), http.StatusInternalServerError)
		return
	}

	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()
	claim, err := tx.ExecContext(
		r.Context(),
		`DELETE FROM pending_blob_writes WHERE blob_path = ? AND state = 'pending'`,
		blobKey,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	claimed, err := claim.RowsAffected()
	if err != nil || claimed != 1 {
		http.Error(w, "uploaded ciphertext cleanup ownership changed before message commit", http.StatusConflict)
		return
	}

	_, err = tx.ExecContext(
		r.Context(),
		`INSERT INTO messages(
			id, sender_user_id, sender_device_id, recipient_user_id, recipient_device_id, envelope_json,
			encrypted_blob_path, blob_size, status, expires_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'sent', ?, ?, ?)`,
		messageID,
		principal.userID,
		principal.deviceID,
		metadata.RecipientID,
		metadata.RecipientDeviceID,
		string(metadata.Envelope),
		blobKey,
		metadata.BlobSize,
		expiresAt,
		nowText,
		nowText,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := tx.Commit(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusCreated, messageResponse{
		ID:                messageID,
		SenderID:          principal.userID,
		SenderDeviceID:    principal.deviceID,
		RecipientID:       metadata.RecipientID,
		RecipientDeviceID: metadata.RecipientDeviceID,
		Envelope:          metadata.Envelope,
		EncryptedBlobPath: blobKey,
		BlobSize:          metadata.BlobSize,
		Status:            "sent",
		CreatedAt:         nowText,
		ExpiresAt:         expiresAt,
	})
}

func (s *Server) handleMessageByID(w http.ResponseWriter, r *http.Request) {
	rest := strings.Trim(strings.TrimPrefix(r.URL.Path, "/messages/"), "/")
	if rest == "" {
		http.NotFound(w, r)
		return
	}

	parts := strings.Split(rest, "/")
	messageID := normalizeID(parts[0])
	if len(parts) == 1 {
		switch r.Method {
		case http.MethodGet:
			s.downloadMessage(w, r, messageID)
		case http.MethodDelete:
			s.deleteMessage(w, r, messageID)
		default:
			methodNotAllowed(w, http.MethodGet, http.MethodDelete)
		}
		return
	}

	if len(parts) == 2 && parts[1] == "delivered" && r.Method == http.MethodPost {
		s.acknowledgeDelivered(w, r, messageID)
		return
	}
	if len(parts) == 2 && parts[1] == "status" && r.Method == http.MethodPatch {
		s.updateMessageStatus(w, r, messageID)
		return
	}

	http.NotFound(w, r)
}

func (s *Server) downloadMessage(w http.ResponseWriter, r *http.Request, messageID string) {
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}

	message, err := s.lookupMessage(r.Context(), messageID, principal.userID)
	if errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if message.EncryptedBlobPath == "" {
		http.Error(w, "relay blob has already been deleted", http.StatusGone)
		return
	}

	body, err := s.store.Read(r.Context(), message.EncryptedBlobPath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusGone)
		return
	}
	defer body.Close()

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Speakeasy-Envelope", base64.StdEncoding.EncodeToString(message.Envelope))
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, body)
}

func (s *Server) acknowledgeDelivered(w http.ResponseWriter, r *http.Request, messageID string) {
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}

	s.blobMutationMu.Lock()
	defer s.blobMutationMu.Unlock()

	message, err := s.lookupMessage(r.Context(), messageID, principal.userID)
	if errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if message.RecipientID != principal.userID {
		http.Error(w, "only the recipient can acknowledge delivery", http.StatusForbidden)
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
	if message.EncryptedBlobPath != "" {
		if err := s.store.Delete(r.Context(), message.EncryptedBlobPath); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}

	result, err := s.db.ExecContext(
		r.Context(),
		`UPDATE messages
		    SET status = CASE WHEN status = 'watched' THEN 'watched' ELSE 'delivered' END,
		        delivered_at = COALESCE(delivered_at, ?),
		        blob_deleted_at = COALESCE(blob_deleted_at, ?), encrypted_blob_path = '',
		        updated_at = ?
		  WHERE id = ? AND recipient_user_id = ? AND status IN ('sent', 'delivered', 'watched')`,
		now,
		now,
		now,
		messageID,
		principal.userID,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	updated, err := result.RowsAffected()
	if err != nil || updated != 1 {
		http.Error(w, "message status changed concurrently", http.StatusConflict)
		return
	}
	status := "delivered"
	if message.Status == "watched" {
		status = "watched"
	}

	writeJSON(w, http.StatusOK, deliveredResponse{
		MessageID:   messageID,
		Status:      status,
		BlobDeleted: true,
	})
}

func (s *Server) updateMessageStatus(w http.ResponseWriter, r *http.Request, messageID string) {
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}

	var req updateStatusRequest
	if !readJSON(w, r, &req) {
		return
	}
	if req.Status != "watched" {
		http.Error(w, "only watched status is supported by this scaffold", http.StatusBadRequest)
		return
	}

	s.blobMutationMu.Lock()
	defer s.blobMutationMu.Unlock()

	message, err := s.lookupMessage(r.Context(), messageID, principal.userID)
	if errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if message.RecipientID != principal.userID {
		http.Error(w, "only the recipient can mark a message watched", http.StatusForbidden)
		return
	}
	if message.EncryptedBlobPath != "" || (message.Status != "delivered" && message.Status != "watched") {
		http.Error(w, "message must be delivered and its relay blob deleted before it can be watched", http.StatusConflict)
		return
	}

	now := s.now().UTC().Format(time.RFC3339)
	result, err := s.db.ExecContext(
		r.Context(),
		`UPDATE messages
		    SET status = 'watched', watched_at = COALESCE(watched_at, ?), updated_at = ?
		  WHERE id = ? AND recipient_user_id = ? AND encrypted_blob_path = ''
		    AND status IN ('delivered', 'watched')`,
		now,
		now,
		messageID,
		principal.userID,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	updated, err := result.RowsAffected()
	if err != nil || updated != 1 {
		http.Error(w, "message status changed concurrently", http.StatusConflict)
		return
	}

	message, err = s.lookupMessage(r.Context(), messageID, principal.userID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, message)
}

func (s *Server) deleteMessage(w http.ResponseWriter, r *http.Request, messageID string) {
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}

	s.blobMutationMu.Lock()
	defer s.blobMutationMu.Unlock()

	message, err := s.lookupMessage(r.Context(), messageID, principal.userID)
	if errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if message.EncryptedBlobPath != "" {
		if err := s.store.Delete(r.Context(), message.EncryptedBlobPath); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}

	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := s.db.ExecContext(
		r.Context(),
		`UPDATE messages
		    SET status = 'deleted', encrypted_blob_path = '', blob_deleted_at = COALESCE(blob_deleted_at, ?),
		        updated_at = ?
		  WHERE id = ?`,
		now,
		now,
		messageID,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleBlocks(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}

	var req blockRequest
	if !readJSON(w, r, &req) {
		return
	}
	req.BlockedUserID = normalizeID(req.BlockedUserID)
	if req.BlockedUserID == "" || req.BlockedUserID == principal.userID {
		http.Error(w, "blockedUserID is invalid", http.StatusBadRequest)
		return
	}

	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(
		r.Context(),
		`INSERT OR IGNORE INTO blocks(blocker_user_id, blocked_user_id) VALUES (?, ?)`,
		principal.userID,
		req.BlockedUserID,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if _, err := tx.ExecContext(
		r.Context(),
		`DELETE FROM contacts WHERE user_id = ? AND contact_user_id = ?`,
		principal.userID,
		req.BlockedUserID,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if err := tx.Commit(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleReports(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		methodNotAllowed(w, http.MethodPost)
		return
	}
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if !s.allowRate(w, s.reportAccountLimiter, principal.userID) {
		return
	}

	var req reportRequest
	if !readJSON(w, r, &req) {
		return
	}
	req.ReportedUserID = normalizeID(req.ReportedUserID)
	req.MessageID = normalizeID(req.MessageID)
	req.Reason = strings.TrimSpace(req.Reason)
	if req.Reason == "" {
		http.Error(w, "reason is required", http.StatusBadRequest)
		return
	}
	if !utf8.ValidString(req.Reason) || len(req.Reason) > maxReportReasonUTF8Bytes {
		http.Error(w, "reason must be valid UTF-8 and at most 128 bytes", http.StatusBadRequest)
		return
	}
	if !utf8.ValidString(req.Details) || len(req.Details) > maxReportDetailsUTF8Bytes {
		http.Error(w, "details must be valid UTF-8 and at most 4096 bytes", http.StatusBadRequest)
		return
	}

	s.abuseWriteMu.Lock()
	defer s.abuseWriteMu.Unlock()
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()
	var accountRecords int
	if err := tx.QueryRowContext(
		r.Context(),
		`SELECT COUNT(*) FROM reports WHERE reporter_user_id = ?`,
		principal.userID,
	).Scan(&accountRecords); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if accountRecords >= s.options.MaxReportRecordsPerAccount {
		http.Error(w, "account report record capacity reached", http.StatusInsufficientStorage)
		return
	}
	var totalRecords int
	if err := tx.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM reports`).Scan(&totalRecords); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if totalRecords >= s.options.MaxReportRecordsTotal {
		http.Error(w, "relay report record capacity reached", http.StatusInsufficientStorage)
		return
	}

	_, err = tx.ExecContext(
		r.Context(),
		`INSERT INTO reports(id, reporter_user_id, reported_user_id, message_id, reason, details)
		 VALUES (?, ?, NULLIF(?, ''), NULLIF(?, ''), ?, ?)`,
		mustID(),
		principal.userID,
		req.ReportedUserID,
		req.MessageID,
		req.Reason,
		req.Details,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := tx.Commit(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) authenticate(w http.ResponseWriter, r *http.Request) (principal, bool) {
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	token, ok := strings.CutPrefix(auth, "Bearer ")
	if !ok || strings.TrimSpace(token) == "" {
		http.Error(w, "missing bearer token", http.StatusUnauthorized)
		return principal{}, false
	}

	var p principal
	err := s.db.QueryRowContext(
		r.Context(),
		`SELECT user_id, device_id FROM sessions
		  WHERE token = ? AND expires_at > ?`,
		bearerTokenHash(token),
		s.now().UTC().Format(time.RFC3339),
	).Scan(&p.userID, &p.deviceID)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "invalid bearer token", http.StatusUnauthorized)
		return principal{}, false
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return principal{}, false
	}
	return p, true
}

func (s *Server) lookupContact(ctx context.Context, userID string, contactID string) (contactResponse, error) {
	var contact contactResponse
	err := s.db.QueryRowContext(
		ctx,
		`SELECT c.user_id, c.contact_user_id, u.username, COALESCE(c.nickname, ''),
		        d.id, d.encryption_public_key, d.signing_public_key, c.created_at
		   FROM contacts c
		   JOIN users u ON u.id = c.contact_user_id
		   JOIN devices d ON d.user_id = c.contact_user_id
		  WHERE c.user_id = ? AND c.contact_user_id = ?
		  ORDER BY d.created_at ASC
		  LIMIT 1`,
		userID,
		contactID,
	).Scan(
		&contact.UserID,
		&contact.ContactID,
		&contact.Username,
		&contact.Nickname,
		&contact.DeviceID,
		&contact.EncryptionPublicKey,
		&contact.SigningPublicKey,
		&contact.CreatedAt,
	)
	return contact, err
}

func (s *Server) lookupMessage(ctx context.Context, messageID string, userID string) (messageResponse, error) {
	row := s.db.QueryRowContext(
		ctx,
		`SELECT id, sender_user_id, sender_device_id, recipient_user_id,
		        COALESCE(recipient_device_id, ''), envelope_json, encrypted_blob_path,
		        blob_size, status, COALESCE(delivered_at, ''), COALESCE(blob_deleted_at, ''),
		        created_at, expires_at
		   FROM messages
		  WHERE id = ? AND (sender_user_id = ? OR recipient_user_id = ?)
		    AND status NOT IN ('deleted', 'expired')`,
		messageID,
		userID,
		userID,
	)
	return scanMessage(row)
}

func scanMessage(scanner interface {
	Scan(dest ...any) error
}) (messageResponse, error) {
	var message messageResponse
	var envelopeText string
	err := scanner.Scan(
		&message.ID,
		&message.SenderID,
		&message.SenderDeviceID,
		&message.RecipientID,
		&message.RecipientDeviceID,
		&envelopeText,
		&message.EncryptedBlobPath,
		&message.BlobSize,
		&message.Status,
		&message.DeliveredAt,
		&message.BlobDeletedAt,
		&message.CreatedAt,
		&message.ExpiresAt,
	)
	if err != nil {
		return messageResponse{}, err
	}
	message.Envelope = json.RawMessage(envelopeText)
	return message, nil
}

func (s *Server) hasContact(ctx context.Context, userID string, contactID string) (bool, error) {
	var value int
	err := s.db.QueryRowContext(
		ctx,
		`SELECT 1 FROM contacts WHERE user_id = ? AND contact_user_id = ?`,
		userID,
		contactID,
	).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (s *Server) deviceBelongsToUser(ctx context.Context, deviceID string, userID string) (bool, error) {
	var value int
	err := s.db.QueryRowContext(
		ctx,
		`SELECT 1 FROM devices WHERE id = ? AND user_id = ?`,
		deviceID,
		userID,
	).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (s *Server) isBlocked(ctx context.Context, senderID string, recipientID string) (bool, error) {
	var value int
	err := s.db.QueryRowContext(
		ctx,
		`SELECT 1 FROM blocks WHERE blocker_user_id = ? AND blocked_user_id = ?`,
		recipientID,
		senderID,
	).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (s *Server) blobSize(key string) (int64, error) {
	fullPath, err := s.store.Path(key)
	if err != nil {
		return 0, err
	}
	reader, err := s.store.Read(context.Background(), key)
	if err != nil {
		return 0, err
	}
	defer reader.Close()

	if seeker, ok := reader.(interface {
		Seek(offset int64, whence int) (int64, error)
	}); ok {
		return seeker.Seek(0, io.SeekEnd)
	}

	return 0, fmt.Errorf("blob %q is not seekable at %s", key, fullPath)
}

func readJSON(w http.ResponseWriter, r *http.Request, target any) bool {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return false
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func methodNotAllowed(w http.ResponseWriter, methods ...string) {
	w.Header().Set("Allow", strings.Join(methods, ", "))
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
}

func normalizeID(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

func validateUsername(username string) error {
	if username == "" {
		return errors.New("must not be empty after trimming whitespace")
	}
	if !utf8.ValidString(username) {
		return errors.New("must be valid UTF-8")
	}
	if len(username) > maxUsernameUTF8Bytes {
		return fmt.Errorf("must be at most %d UTF-8 bytes", maxUsernameUTF8Bytes)
	}
	for _, r := range username {
		if unicode.IsControl(r) {
			return errors.New("must not contain Unicode control characters")
		}
	}
	return nil
}

func validateAuthenticatedEnvelope(raw json.RawMessage, senderDeviceID string, recipientDeviceID string) error {
	if len(raw) > maxAuthenticatedEnvelopeBytes {
		return fmt.Errorf("envelope must be at most %d bytes", maxAuthenticatedEnvelopeBytes)
	}
	if !utf8.Valid(raw) {
		return errors.New("envelope JSON must be valid UTF-8")
	}

	var envelope authenticatedMessageEnvelope
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&envelope); err != nil {
		return fmt.Errorf("malformed JSON, base64 data, or field type: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("envelope must contain exactly one JSON value")
	}
	if envelope.Version != authenticatedEnvelopeV2 {
		return fmt.Errorf("version must be %d", authenticatedEnvelopeV2)
	}
	if !isNonzeroUUID(envelope.ClientMessageID) {
		return errors.New("clientMessageID must be a nonzero UUID")
	}
	if !strings.EqualFold(envelope.SenderDeviceID, senderDeviceID) {
		return errors.New("senderDeviceID does not match authenticated device")
	}
	if !strings.EqualFold(envelope.RecipientDeviceID, recipientDeviceID) {
		return errors.New("recipientDeviceID does not match upload metadata")
	}
	if len(envelope.SenderIdentityDigest) != identityDigestSize {
		return fmt.Errorf("senderIdentityDigest must decode to exactly %d bytes", identityDigestSize)
	}
	if len(envelope.RecipientIdentityDigest) != identityDigestSize {
		return fmt.Errorf("recipientIdentityDigest must decode to exactly %d bytes", identityDigestSize)
	}
	if envelope.AuthenticationAlgorithm != ed25519AuthenticationAlgorithm {
		return fmt.Errorf("authenticationAlgorithm must be %s", ed25519AuthenticationAlgorithm)
	}
	if len(envelope.Signature) != ed25519SignatureSize {
		return fmt.Errorf("signature must decode to exactly %d bytes", ed25519SignatureSize)
	}
	if envelope.Media.Algorithm != xChaCha20Poly1305Algorithm {
		return fmt.Errorf("media.algorithm must be %s", xChaCha20Poly1305Algorithm)
	}
	if len(envelope.Media.Nonce) != xChaCha20Poly1305NonceSize {
		return fmt.Errorf("media.nonce must decode to exactly %d bytes", xChaCha20Poly1305NonceSize)
	}
	if len(envelope.Media.CiphertextHash) != ciphertextHashSize {
		return fmt.Errorf("media.ciphertextHash must decode to exactly %d bytes", ciphertextHashSize)
	}
	if err := validateEnvelopeString(
		envelope.Media.MIMEType,
		"media.mimeType",
		maxEnvelopeMIMETypeUTF8Bytes,
	); err != nil {
		return err
	}
	if envelope.Media.DurationSeconds != nil {
		seconds := *envelope.Media.DurationSeconds
		milliseconds := math.Floor(seconds*1_000 + 0.5)
		if math.IsNaN(seconds) || math.IsInf(seconds, 0) || seconds < 0 ||
			math.IsNaN(milliseconds) || math.IsInf(milliseconds, 0) ||
			milliseconds >= 18446744073709551616.0 {
			return errors.New("media.durationSeconds must be finite, nonnegative, and representable as unsigned milliseconds")
		}
	}
	if err := validateAuthenticatedContentKey(envelope.ContentKey, "contentKey"); err != nil {
		return err
	}
	if envelope.SenderContentKey != nil {
		if err := validateAuthenticatedContentKey(*envelope.SenderContentKey, "senderContentKey"); err != nil {
			return err
		}
	}
	if envelope.Media.Thumbnail != nil {
		thumbnail := envelope.Media.Thumbnail
		if thumbnail.Algorithm != xChaCha20Poly1305Algorithm {
			return fmt.Errorf("media.thumbnail.algorithm must be %s", xChaCha20Poly1305Algorithm)
		}
		if len(thumbnail.Nonce) != xChaCha20Poly1305NonceSize {
			return fmt.Errorf("media.thumbnail.nonce must decode to exactly %d bytes", xChaCha20Poly1305NonceSize)
		}
		if err := validateEnvelopeString(
			thumbnail.EncryptedBlobPath,
			"media.thumbnail.encryptedBlobPath",
			maxThumbnailPathUTF8Bytes,
		); err != nil {
			return err
		}
		if len(thumbnail.CiphertextHash) != ciphertextHashSize {
			return fmt.Errorf("media.thumbnail.ciphertextHash must decode to exactly %d bytes", ciphertextHashSize)
		}
	}
	createdAt, err := time.Parse(authenticatedCreatedAtLayout, envelope.CreatedAt)
	if err != nil || createdAt.Format(authenticatedCreatedAtLayout) != envelope.CreatedAt {
		return errors.New("createdAt must use UTC ISO 8601 whole-second format (YYYY-MM-DDTHH:MM:SSZ)")
	}
	return nil
}

func validateAuthenticatedContentKey(key authenticatedEnvelopeContentKey, field string) error {
	if key.Algorithm != sealedContentKeyAlgorithm {
		return fmt.Errorf("%s.algorithm must be %s", field, sealedContentKeyAlgorithm)
	}
	if len(key.EncryptedContentKey) != sealedContentKeySize {
		return fmt.Errorf("%s.encryptedContentKey must decode to exactly %d bytes", field, sealedContentKeySize)
	}
	if key.RecipientPublicKeyFingerprint != nil {
		if err := validateEnvelopeString(
			*key.RecipientPublicKeyFingerprint,
			field+".recipientPublicKeyFingerprint",
			maxKeyFingerprintUTF8Bytes,
		); err != nil {
			return err
		}
	}
	return nil
}

func validateEnvelopeString(value string, field string, maxUTF8Bytes int) error {
	if value == "" {
		return fmt.Errorf("%s must be non-empty", field)
	}
	if len(value) > maxUTF8Bytes {
		return fmt.Errorf("%s must be at most %d UTF-8 bytes", field, maxUTF8Bytes)
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return fmt.Errorf("%s must not contain Unicode control characters", field)
		}
	}
	return nil
}

func isNonzeroUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}

	decoded, err := hex.DecodeString(strings.ReplaceAll(value, "-", ""))
	if err != nil || len(decoded) != 16 {
		return false
	}
	for _, b := range decoded {
		if b != 0 {
			return true
		}
	}
	return false
}

func mustID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf(
		"%x-%x-%x-%x-%x",
		b[0:4],
		b[4:6],
		b[6:8],
		b[8:10],
		b[10:16],
	)
}

func mustToken() string {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b[:])
}

func mustInviteCode() string {
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	encoded := strings.ToUpper(hex.EncodeToString(b[:]))
	return "SPEAK-" + encoded[:4] + "-" + encoded[4:8] + "-" + encoded[8:]
}
