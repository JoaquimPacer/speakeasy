package api

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/joaquimpacer/speakeasy/server/internal/db"
	"github.com/joaquimpacer/speakeasy/server/internal/storage"
)

func TestAcceptInviteIsTransactionallySingleUse(t *testing.T) {
	const contenderCount = 4

	ctx := context.Background()
	databasePath := filepath.Join(t.TempDir(), "invite-race.db") +
		"?_pragma=busy_timeout%3d5000&_pragma=foreign_keys%3d1"
	database, err := db.Open(ctx, databasePath)
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })
	database.SetMaxOpenConns(contenderCount + 1)
	database.SetMaxIdleConns(contenderCount + 1)

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}
	relay := NewWithOptions(database, blobStore, Options{RetentionDays: 7})
	handler := relay.Handler()

	now := time.Now().UTC().Truncate(time.Second)
	nowText := now.Format(time.RFC3339)
	expiresAt := now.Add(time.Hour).Format(time.RFC3339)
	inviterID := mustID()
	inviterDeviceID := mustID()
	insertInviteTestIdentity(t, database, inviterID, inviterDeviceID, "invite-owner", "", nowText, expiresAt)

	type contender struct {
		userID string
		token  string
	}
	contenders := make([]contender, 0, contenderCount)
	for index := 0; index < contenderCount; index++ {
		userID := mustID()
		deviceID := mustID()
		token := fmt.Sprintf("invite-contender-token-%d", index)
		insertInviteTestIdentity(
			t,
			database,
			userID,
			deviceID,
			fmt.Sprintf("invite-contender-%d", index),
			token,
			nowText,
			expiresAt,
		)
		contenders = append(contenders, contender{userID: userID, token: token})
	}

	const inviteCode = "SPEAK-RACE-TEST"
	if _, err := database.ExecContext(
		ctx,
		`INSERT INTO invites(id, code, inviter_user_id, inviter_device_id, expires_at, created_at)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		mustID(),
		inviteCode,
		inviterID,
		inviterDeviceID,
		expiresAt,
		nowText,
	); err != nil {
		t.Fatalf("insert invite: %v", err)
	}

	// Hold SQLite's writer lock until every request has authenticated, opened its
	// transaction, and reached the invite claim. Releasing the lock then forces
	// all contenders to race on the conditional status transition.
	writer, err := database.BeginTx(ctx, nil)
	if err != nil {
		t.Fatalf("begin writer transaction: %v", err)
	}
	writerOpen := true
	defer func() {
		if writerOpen {
			_ = writer.Rollback()
		}
	}()
	if _, err := writer.ExecContext(
		ctx,
		`UPDATE users SET updated_at = ? WHERE id = ?`,
		now.Add(time.Second).Format(time.RFC3339),
		inviterID,
	); err != nil {
		t.Fatalf("acquire writer lock: %v", err)
	}

	type acceptanceResult struct {
		userID string
		status int
	}
	start := make(chan struct{})
	results := make(chan acceptanceResult, contenderCount)
	for _, candidate := range contenders {
		candidate := candidate
		go func() {
			<-start
			request := httptest.NewRequest(
				http.MethodPost,
				"http://relay.test/contacts/accept",
				bytes.NewBufferString(`{"code":"`+inviteCode+`"}`),
			)
			request.Header.Set("Authorization", "Bearer "+candidate.token)
			request.Header.Set("Content-Type", "application/json")
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			results <- acceptanceResult{userID: candidate.userID, status: response.Code}
		}()
	}
	close(start)

	wantInUse := contenderCount + 1 // every contender plus the lock holder
	deadline := time.Now().Add(2 * time.Second)
	for database.Stats().InUse < wantInUse && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	observedInUse := database.Stats().InUse
	reachedClaimBarrier := observedInUse == wantInUse
	if err := writer.Commit(); err != nil {
		t.Fatalf("release writer lock: %v", err)
	}
	writerOpen = false

	acceptedUserID := ""
	acceptedCount := 0
	for range contenderCount {
		result := <-results
		switch result.status {
		case http.StatusOK:
			acceptedCount++
			acceptedUserID = result.userID
		case http.StatusNotFound:
			// Every loser must observe that the single-use capability was consumed.
		default:
			t.Fatalf("concurrent invite acceptance status = %d, want 200 or 404", result.status)
		}
	}
	if !reachedClaimBarrier {
		t.Fatalf("only %d database connections reached the invite claim, want %d", observedInUse, wantInUse)
	}
	if acceptedCount != 1 {
		t.Fatalf("successful invite acceptances = %d, want exactly 1", acceptedCount)
	}

	var status string
	var acceptedBy string
	if err := database.QueryRowContext(
		ctx,
		`SELECT status, accepted_by_user_id FROM invites WHERE code = ?`,
		inviteCode,
	).Scan(&status, &acceptedBy); err != nil {
		t.Fatalf("read accepted invite: %v", err)
	}
	if status != "accepted" || acceptedBy != acceptedUserID {
		t.Fatalf("accepted invite = status %q user %q, want accepted by %q", status, acceptedBy, acceptedUserID)
	}

	var contactRows int
	if err := database.QueryRowContext(
		ctx,
		`SELECT COUNT(*) FROM contacts
		  WHERE (user_id = ? AND contact_user_id = ?)
		     OR (user_id = ? AND contact_user_id = ?)`,
		inviterID,
		acceptedUserID,
		acceptedUserID,
		inviterID,
	).Scan(&contactRows); err != nil {
		t.Fatalf("count accepted contact rows: %v", err)
	}
	if contactRows != 2 {
		t.Fatalf("accepted contact rows = %d, want 2", contactRows)
	}
}

func insertInviteTestIdentity(
	t *testing.T,
	database *sql.DB,
	userID string,
	deviceID string,
	username string,
	token string,
	now string,
	expiresAt string,
) {
	t.Helper()
	ctx := context.Background()
	if _, err := database.ExecContext(
		ctx,
		`INSERT INTO users(id, username, created_at, updated_at) VALUES (?, ?, ?, ?)`,
		userID,
		username,
		now,
		now,
	); err != nil {
		t.Fatalf("insert invite-test user: %v", err)
	}
	if _, err := database.ExecContext(
		ctx,
		`INSERT INTO devices(
			id, user_id, name, encryption_public_key, signing_public_key, created_at, updated_at
		 ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		deviceID,
		userID,
		username+" iPhone",
		bytes.Repeat([]byte{0x11}, 32),
		bytes.Repeat([]byte{0x22}, 32),
		now,
		now,
	); err != nil {
		t.Fatalf("insert invite-test device: %v", err)
	}
	if token == "" {
		return
	}
	if _, err := database.ExecContext(
		ctx,
		`INSERT INTO sessions(token, user_id, device_id, expires_at, created_at)
		 VALUES (?, ?, ?, ?, ?)`,
		bearerTokenHash(token),
		userID,
		deviceID,
		expiresAt,
		now,
	); err != nil {
		t.Fatalf("insert invite-test session: %v", err)
	}
}
