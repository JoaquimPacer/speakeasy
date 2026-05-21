package api

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/joaquimpacer/speakeasy/server/internal/storage"
)

const maxUploadBytes = 512 << 20

type Server struct {
	db            *sql.DB
	store         storage.Store
	startedAt     time.Time
	retentionDays int
}

func New(db *sql.DB, store storage.Store, retentionDays int) *Server {
	return &Server{
		db:            db,
		store:         store,
		startedAt:     time.Now().UTC(),
		retentionDays: retentionDays,
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/auth/register", s.handleRegister)
	mux.HandleFunc("/contacts/invite", s.handleCreateInvite)
	mux.HandleFunc("/contacts/accept", s.handleAcceptInvite)
	mux.HandleFunc("/contacts", s.handleContacts)
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

type contactResponse struct {
	UserID              string `json:"userID"`
	ContactID           string `json:"contactID"`
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
	RecipientID string          `json:"recipientID"`
	Envelope    json.RawMessage `json:"envelope"`
	BlobSize    int64           `json:"blobSize"`
	DurationMs  int64           `json:"durationMs"`
}

type messageResponse struct {
	ID                string          `json:"id"`
	SenderID          string          `json:"senderID"`
	RecipientID       string          `json:"recipientID"`
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

	var req registerRequest
	if !readJSON(w, r, &req) {
		return
	}

	req.Username = strings.TrimSpace(req.Username)
	req.DeviceName = strings.TrimSpace(req.DeviceName)
	if req.Username == "" || len(req.EncryptionPublicKey) == 0 || len(req.SigningPublicKey) == 0 {
		http.Error(w, "username, encryptionPublicKey, and signingPublicKey are required", http.StatusBadRequest)
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
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
		`INSERT INTO sessions(token, user_id, device_id, created_at) VALUES (?, ?, ?, ?)`,
		token,
		userID,
		deviceID,
		now,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if err := tx.Commit(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

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
	})
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

	inviteID := mustID()
	code := mustInviteCode()
	expiresAt := time.Now().UTC().Add(7 * 24 * time.Hour).Format(time.RFC3339)
	now := time.Now().UTC().Format(time.RFC3339)

	_, err := s.db.ExecContext(
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

	var inviterID string
	err := s.db.QueryRowContext(
		r.Context(),
		`SELECT inviter_user_id FROM invites
		 WHERE code = ? AND status = 'pending' AND expires_at > ?`,
		code,
		time.Now().UTC().Format(time.RFC3339),
	).Scan(&inviterID)
	if errors.Is(err, sql.ErrNoRows) {
		http.Error(w, "invite not found or expired", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if inviterID == principal.userID {
		http.Error(w, "cannot accept your own invite", http.StatusBadRequest)
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
	tx, err := s.db.BeginTx(r.Context(), nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()

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

	if _, err := tx.ExecContext(
		r.Context(),
		`UPDATE invites SET status = 'accepted', accepted_by_user_id = ?, accepted_at = ? WHERE code = ?`,
		principal.userID,
		now,
		code,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
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
		        d.encryption_public_key, d.signing_public_key, c.created_at
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
		`SELECT id, sender_user_id, recipient_user_id, envelope_json, encrypted_blob_path,
		        blob_size, status, COALESCE(delivered_at, ''), COALESCE(blob_deleted_at, ''),
		        created_at, expires_at
		   FROM messages
		  WHERE (sender_user_id = ? OR recipient_user_id = ?) AND status <> 'deleted'
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

	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBytes)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		http.Error(w, "invalid multipart upload", http.StatusBadRequest)
		return
	}

	metadataPart := r.FormValue("metadata")
	if metadataPart == "" {
		http.Error(w, "metadata part is required", http.StatusBadRequest)
		return
	}

	var metadata uploadMetadata
	if err := json.Unmarshal([]byte(metadataPart), &metadata); err != nil {
		http.Error(w, "invalid metadata JSON", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(metadata.RecipientID) == "" || len(metadata.Envelope) == 0 {
		http.Error(w, "recipientID and envelope are required", http.StatusBadRequest)
		return
	}

	file, _, err := r.FormFile("blob")
	if err != nil {
		http.Error(w, "blob part is required", http.StatusBadRequest)
		return
	}
	defer file.Close()

	if blocked, err := s.isBlocked(r.Context(), principal.userID, metadata.RecipientID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	} else if blocked {
		http.Error(w, "recipient has blocked sender", http.StatusForbidden)
		return
	}

	messageID := mustID()
	blobKey := "messages/" + messageID + ".blob"
	if err := s.store.Write(r.Context(), blobKey, file); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	now := time.Now().UTC()
	expiresAt := now.Add(time.Duration(s.retentionDays) * 24 * time.Hour).Format(time.RFC3339)
	nowText := now.Format(time.RFC3339)

	if metadata.BlobSize <= 0 {
		if size, err := s.blobSize(blobKey); err == nil {
			metadata.BlobSize = size
		}
	}

	_, err = s.db.ExecContext(
		r.Context(),
		`INSERT INTO messages(
			id, sender_user_id, sender_device_id, recipient_user_id, envelope_json,
			encrypted_blob_path, blob_size, status, expires_at, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, 'sent', ?, ?, ?)`,
		messageID,
		principal.userID,
		principal.deviceID,
		metadata.RecipientID,
		string(metadata.Envelope),
		blobKey,
		metadata.BlobSize,
		expiresAt,
		nowText,
		nowText,
	)
	if err != nil {
		_ = s.store.Delete(context.Background(), blobKey)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusCreated, messageResponse{
		ID:                messageID,
		SenderID:          principal.userID,
		RecipientID:       metadata.RecipientID,
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
	messageID := parts[0]
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

	_, err = s.db.ExecContext(
		r.Context(),
		`UPDATE messages
		    SET status = 'delivered', delivered_at = COALESCE(delivered_at, ?),
		        blob_deleted_at = COALESCE(blob_deleted_at, ?), encrypted_blob_path = '',
		        updated_at = ?
		  WHERE id = ?`,
		now,
		now,
		now,
		messageID,
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, deliveredResponse{
		MessageID:   messageID,
		Status:      "delivered",
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

	if _, err := s.lookupMessage(r.Context(), messageID, principal.userID); errors.Is(err, sql.ErrNoRows) {
		http.NotFound(w, r)
		return
	} else if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := s.db.ExecContext(
		r.Context(),
		`UPDATE messages SET status = 'watched', watched_at = ?, updated_at = ? WHERE id = ?`,
		now,
		now,
		messageID,
	); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	message, err := s.lookupMessage(r.Context(), messageID, principal.userID)
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
		_ = s.store.Delete(r.Context(), message.EncryptedBlobPath)
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
	if strings.TrimSpace(req.BlockedUserID) == "" || req.BlockedUserID == principal.userID {
		http.Error(w, "blockedUserID is invalid", http.StatusBadRequest)
		return
	}

	_, err := s.db.ExecContext(
		r.Context(),
		`INSERT OR IGNORE INTO blocks(blocker_user_id, blocked_user_id) VALUES (?, ?)`,
		principal.userID,
		req.BlockedUserID,
	)
	if err != nil {
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

	var req reportRequest
	if !readJSON(w, r, &req) {
		return
	}
	req.Reason = strings.TrimSpace(req.Reason)
	if req.Reason == "" {
		http.Error(w, "reason is required", http.StatusBadRequest)
		return
	}

	_, err := s.db.ExecContext(
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
		  WHERE token = ? AND (expires_at IS NULL OR expires_at > ?)`,
		token,
		time.Now().UTC().Format(time.RFC3339),
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
		        d.encryption_public_key, d.signing_public_key, c.created_at
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
		&contact.EncryptionPublicKey,
		&contact.SigningPublicKey,
		&contact.CreatedAt,
	)
	return contact, err
}

func (s *Server) lookupMessage(ctx context.Context, messageID string, userID string) (messageResponse, error) {
	row := s.db.QueryRowContext(
		ctx,
		`SELECT id, sender_user_id, recipient_user_id, envelope_json, encrypted_blob_path,
		        blob_size, status, COALESCE(delivered_at, ''), COALESCE(blob_deleted_at, ''),
		        created_at, expires_at
		   FROM messages
		  WHERE id = ? AND (sender_user_id = ? OR recipient_user_id = ?) AND status <> 'deleted'`,
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
		&message.RecipientID,
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
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
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
