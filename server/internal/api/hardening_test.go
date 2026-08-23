package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/joaquimpacer/speakeasy/server/internal/db"
	"github.com/joaquimpacer/speakeasy/server/internal/storage"
)

type failingDeleteStore struct {
	storage.Store
	mu            sync.Mutex
	failDeletes   bool
	failDeleteKey string
}

func (s *failingDeleteStore) Delete(ctx context.Context, key string) error {
	s.mu.Lock()
	fail := s.failDeletes || s.failDeleteKey == key
	s.mu.Unlock()
	if fail {
		return errors.New("injected delete failure")
	}
	return s.Store.Delete(ctx, key)
}

func (s *failingDeleteStore) setFailDeletes(fail bool) {
	s.mu.Lock()
	s.failDeletes = fail
	s.mu.Unlock()
}

func (s *failingDeleteStore) setFailDeleteKey(key string) {
	s.mu.Lock()
	s.failDeleteKey = key
	s.mu.Unlock()
}

func TestDeleteMessageKeepsBlobPathWhenStorageDeletionFails(t *testing.T) {
	database, relay, blobStore := newHardeningTestRelay(t, Options{RetentionDays: 7})
	alice, bob, message := createPendingTestMessage(t, relay.URL)

	blobStore.setFailDeletes(true)
	request := authedRequest(t, http.MethodDelete, relay.URL+"/messages/"+message.ID, alice.BearerToken, nil)
	doRequest(t, request, http.StatusInternalServerError, nil)

	var status string
	var blobPath string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT status, encrypted_blob_path FROM messages WHERE id = ?`,
		message.ID,
	).Scan(&status, &blobPath); err != nil {
		t.Fatalf("read message after failed deletion: %v", err)
	}
	if status != "sent" || blobPath == "" {
		t.Fatalf("message after failed deletion = status %q path %q, want sent with retained path", status, blobPath)
	}
	if statusCode := downloadMessageStatus(t, relay.URL, bob.BearerToken, message.ID); statusCode != http.StatusOK {
		t.Fatalf("blob after failed deletion status = %d, want %d", statusCode, http.StatusOK)
	}

	blobStore.setFailDeletes(false)
	request = authedRequest(t, http.MethodDelete, relay.URL+"/messages/"+message.ID, alice.BearerToken, nil)
	doRequest(t, request, http.StatusNoContent, nil)
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT status, encrypted_blob_path FROM messages WHERE id = ?`,
		message.ID,
	).Scan(&status, &blobPath); err != nil {
		t.Fatalf("read message after successful deletion: %v", err)
	}
	if status != "deleted" || blobPath != "" {
		t.Fatalf("message after successful deletion = status %q path %q, want deleted with empty path", status, blobPath)
	}
}

func TestDeleteAccountRetriesSenderRecipientAndPendingCiphertextSafely(t *testing.T) {
	database, relay, blobStore := newHardeningTestRelay(t, Options{RetentionDays: 7})
	alice, bob, incoming := createPendingTestMessage(t, relay.URL)
	outgoing := uploadTestMessage(
		t,
		relay.URL,
		bob.BearerToken,
		alice.User.ID,
		alice.Device.ID,
		validTestEnvelope(t, bob.Device.ID, alice.Device.ID),
		[]byte("outgoing pending ciphertext"),
	)

	const pendingAsSender = "messages/000-account-delete-pending-sender.blob"
	const pendingAsRecipient = "messages/zzz-account-delete-pending-recipient.blob"
	const unrelatedPending = "messages/zzzz-account-delete-unrelated.blob"
	pendingWrites := []struct {
		path        string
		senderID    string
		recipientID string
		ciphertext  string
		state       string
	}{
		{pendingAsSender, bob.User.ID, alice.User.ID, "pending as sender", "pending"},
		{pendingAsRecipient, alice.User.ID, bob.User.ID, "pending as recipient", "cleaning"},
		{unrelatedPending, "unrelated-sender", "unrelated-recipient", "unrelated pending", "pending"},
	}
	for _, pending := range pendingWrites {
		if _, err := database.ExecContext(
			context.Background(),
			`INSERT INTO pending_blob_writes(
				blob_path, sender_user_id, recipient_user_id, blob_size, state, created_at
			 ) VALUES (?, ?, ?, ?, ?, ?)`,
			pending.path,
			pending.senderID,
			pending.recipientID,
			len(pending.ciphertext),
			pending.state,
			time.Now().UTC().Format(time.RFC3339),
		); err != nil {
			t.Fatalf("insert pending blob write %q: %v", pending.path, err)
		}
		if err := blobStore.Write(context.Background(), pending.path, strings.NewReader(pending.ciphertext)); err != nil {
			t.Fatalf("write pending ciphertext %q: %v", pending.path, err)
		}
	}

	// Deletion is ordered by path. This failure occurs after pendingAsSender has
	// been deleted and before pendingAsRecipient, proving that a partial storage
	// pass leaves every ownership row and the authenticated session retryable.
	blobStore.setFailDeleteKey(incoming.EncryptedBlobPath)

	request := authedRequest(t, http.MethodDelete, relay.URL+"/account", bob.BearerToken, nil)
	doRequest(t, request, http.StatusInternalServerError, nil)

	var userCount int
	if err := database.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM users WHERE id = ?`, bob.User.ID).Scan(&userCount); err != nil {
		t.Fatalf("count user after failed account deletion: %v", err)
	}
	if userCount != 1 {
		t.Fatalf("user count after failed account deletion = %d, want 1", userCount)
	}
	var messageCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM messages WHERE id IN (?, ?)`,
		incoming.ID,
		outgoing.ID,
	).Scan(&messageCount); err != nil {
		t.Fatalf("count messages after failed account deletion: %v", err)
	}
	if messageCount != 2 {
		t.Fatalf("message count after failed account deletion = %d, want 2", messageCount)
	}
	var relatedPendingCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*)
		   FROM pending_blob_writes
		  WHERE sender_user_id = ? OR recipient_user_id = ?`,
		bob.User.ID,
		bob.User.ID,
	).Scan(&relatedPendingCount); err != nil {
		t.Fatalf("count pending writes after failed account deletion: %v", err)
	}
	if relatedPendingCount != 2 {
		t.Fatalf("pending write count after failed account deletion = %d, want 2", relatedPendingCount)
	}
	var sessionCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM sessions WHERE token = ?`,
		bearerTokenHash(bob.BearerToken),
	).Scan(&sessionCount); err != nil {
		t.Fatalf("count session after failed account deletion: %v", err)
	}
	if sessionCount != 1 {
		t.Fatalf("session count after failed account deletion = %d, want 1", sessionCount)
	}
	if reader, err := blobStore.Read(context.Background(), pendingAsSender); err == nil {
		reader.Close()
		t.Fatal("ciphertext deleted before injected failure unexpectedly remained")
	}
	for _, retainedPath := range []string{incoming.EncryptedBlobPath, pendingAsRecipient} {
		reader, err := blobStore.Read(context.Background(), retainedPath)
		if err != nil {
			t.Fatalf("ciphertext %q after failed account deletion: %v", retainedPath, err)
		}
		reader.Close()
	}

	blobStore.setFailDeleteKey("")
	request = authedRequest(t, http.MethodDelete, relay.URL+"/account", bob.BearerToken, nil)
	doRequest(t, request, http.StatusNoContent, nil)

	if err := database.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM users WHERE id = ?`, bob.User.ID).Scan(&userCount); err != nil {
		t.Fatalf("count user after retried account deletion: %v", err)
	}
	if userCount != 0 {
		t.Fatalf("user count after retried account deletion = %d, want 0", userCount)
	}
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM messages WHERE id IN (?, ?)`,
		incoming.ID,
		outgoing.ID,
	).Scan(&messageCount); err != nil {
		t.Fatalf("count messages after retried account deletion: %v", err)
	}
	if messageCount != 0 {
		t.Fatalf("message count after retried account deletion = %d, want 0", messageCount)
	}
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*)
		   FROM pending_blob_writes
		  WHERE sender_user_id = ? OR recipient_user_id = ?`,
		bob.User.ID,
		bob.User.ID,
	).Scan(&relatedPendingCount); err != nil {
		t.Fatalf("count pending writes after retried account deletion: %v", err)
	}
	if relatedPendingCount != 0 {
		t.Fatalf("pending write count after retried account deletion = %d, want 0", relatedPendingCount)
	}
	for _, deletedPath := range []string{
		incoming.EncryptedBlobPath,
		outgoing.EncryptedBlobPath,
		pendingAsSender,
		pendingAsRecipient,
	} {
		if reader, err := blobStore.Read(context.Background(), deletedPath); err == nil {
			reader.Close()
			t.Fatalf("account ciphertext %q remained after retry", deletedPath)
		}
	}
	var unrelatedPendingCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM pending_blob_writes WHERE blob_path = ?`,
		unrelatedPending,
	).Scan(&unrelatedPendingCount); err != nil {
		t.Fatalf("count unrelated pending write: %v", err)
	}
	if unrelatedPendingCount != 1 {
		t.Fatalf("unrelated pending write count = %d, want 1", unrelatedPendingCount)
	}
	if reader, err := blobStore.Read(context.Background(), unrelatedPending); err != nil {
		t.Fatalf("unrelated pending ciphertext was deleted: %v", err)
	} else {
		reader.Close()
	}
}

func TestUploadRevalidatesAccountsAfterConcurrentDeletion(t *testing.T) {
	tests := []struct {
		name       string
		deleteUser string
		wantStatus int
	}{
		{name: "sender", deleteUser: "sender", wantStatus: http.StatusUnauthorized},
		{name: "recipient", deleteUser: "recipient", wantStatus: http.StatusForbidden},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			database, err := db.Open(context.Background(), ":memory:")
			if err != nil {
				t.Fatalf("db.Open() error = %v", err)
			}
			t.Cleanup(func() { database.Close() })

			localStore, err := storage.NewLocal(t.TempDir())
			if err != nil {
				t.Fatalf("storage.NewLocal() error = %v", err)
			}
			blobStore := &writeTrackingStore{Store: localStore}
			server := NewWithOptions(database, blobStore, Options{RetentionDays: 7})
			relay := httptest.NewServer(server.Handler())
			t.Cleanup(relay.Close)

			alice := registerTestDevice(t, relay.URL, "concurrent-delete-alice-"+test.name)
			bob := registerTestDevice(t, relay.URL, "concurrent-delete-bob-"+test.name)
			invite := createInvite(t, relay.URL, alice.BearerToken)
			_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)

			uploadPaused := make(chan struct{})
			resumeUpload := make(chan struct{})
			var resumeOnce sync.Once
			resume := func() {
				resumeOnce.Do(func() { close(resumeUpload) })
			}
			defer resume()
			server.beforeUploadMutationLock = func() {
				close(uploadPaused)
				<-resumeUpload
			}

			request := newUploadRequest(
				t,
				relay.URL,
				alice.BearerToken,
				bob.User.ID,
				bob.Device.ID,
				validTestEnvelope(t, alice.Device.ID, bob.Device.ID),
				[]byte("concurrent account deletion ciphertext"),
			)
			type uploadResult struct {
				status int
				err    error
			}
			result := make(chan uploadResult, 1)
			go func() {
				response, err := http.DefaultClient.Do(request)
				if err != nil {
					result <- uploadResult{err: err}
					return
				}
				_, _ = io.Copy(io.Discard, response.Body)
				_ = response.Body.Close()
				result <- uploadResult{status: response.StatusCode}
			}()

			select {
			case <-uploadPaused:
			case <-time.After(5 * time.Second):
				t.Fatal("upload did not pause before the blob mutation lock")
			}

			deletedAccount := alice
			if test.deleteUser == "recipient" {
				deletedAccount = bob
			}
			deleteAccount(t, relay.URL, deletedAccount.BearerToken)
			resume()

			select {
			case upload := <-result:
				if upload.err != nil {
					t.Fatalf("upload after account deletion: %v", upload.err)
				}
				if upload.status != test.wantStatus {
					t.Fatalf("upload after %s deletion status = %d, want %d", test.deleteUser, upload.status, test.wantStatus)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("upload did not finish after account deletion")
			}

			if blobStore.writes != 0 {
				t.Fatalf("blob writes after %s deletion = %d, want 0", test.deleteUser, blobStore.writes)
			}
			var pendingCount int
			if err := database.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM pending_blob_writes`).Scan(&pendingCount); err != nil {
				t.Fatalf("count pending writes after concurrent deletion: %v", err)
			}
			if pendingCount != 0 {
				t.Fatalf("pending writes after %s deletion = %d, want 0", test.deleteUser, pendingCount)
			}
			var messageCount int
			if err := database.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM messages`).Scan(&messageCount); err != nil {
				t.Fatalf("count messages after concurrent deletion: %v", err)
			}
			if messageCount != 0 {
				t.Fatalf("messages after %s deletion = %d, want 0", test.deleteUser, messageCount)
			}
		})
	}
}

func TestCleanupExpiredDeletesWatchedRowsWithBlobsAndRetriesFailures(t *testing.T) {
	database, relay, blobStore := newHardeningTestRelay(t, Options{RetentionDays: 7})
	_, _, message := createPendingTestMessage(t, relay.URL)
	if _, err := database.ExecContext(
		context.Background(),
		`UPDATE messages SET status = 'watched', expires_at = ? WHERE id = ?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339),
		message.ID,
	); err != nil {
		t.Fatalf("expire message: %v", err)
	}

	blobStore.setFailDeletes(true)
	// The HTTP test server owns the handler only; construct a server against the
	// same database/store so cleanup can be invoked deterministically.
	cleanupServer := NewWithOptions(database, blobStore, Options{RetentionDays: 7})
	result, err := cleanupServer.CleanupExpired(context.Background())
	if err == nil || result.FailedMessages != 1 || result.DeletedMessages != 0 {
		t.Fatalf("failed cleanup result = %+v, error = %v", result, err)
	}
	var status string
	var blobPath string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT status, encrypted_blob_path FROM messages WHERE id = ?`,
		message.ID,
	).Scan(&status, &blobPath); err != nil {
		t.Fatalf("read retained cleanup row: %v", err)
	}
	if status != "expired" || blobPath == "" {
		t.Fatalf("failed cleanup row = status %q path %q, want expired with retained path", status, blobPath)
	}

	blobStore.setFailDeletes(false)
	result, err = cleanupServer.CleanupExpired(context.Background())
	if err != nil || result.DeletedMessages != 1 || result.FailedMessages != 0 {
		t.Fatalf("retry cleanup result = %+v, error = %v", result, err)
	}
	var rowCount int
	if err := database.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM messages WHERE id = ?`, message.ID).Scan(&rowCount); err != nil {
		t.Fatalf("count cleaned message: %v", err)
	}
	if rowCount != 0 {
		t.Fatalf("cleaned message row count = %d, want 0", rowCount)
	}
	if reader, err := blobStore.Read(context.Background(), blobPath); err == nil {
		reader.Close()
		t.Fatal("expired ciphertext remained after successful retry")
	}
}

func TestCleanupLoopRunsAtStartupAndPeriodically(t *testing.T) {
	database, relay, blobStore := newHardeningTestRelay(t, Options{RetentionDays: 7})
	_, _, message := createPendingTestMessage(t, relay.URL)
	if _, err := database.ExecContext(
		context.Background(),
		`UPDATE messages SET expires_at = ? WHERE id = ?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339),
		message.ID,
	); err != nil {
		t.Fatalf("expire scheduler-test message: %v", err)
	}

	server := NewWithOptions(database, blobStore, Options{RetentionDays: 7})
	ctx, cancel := context.WithCancel(context.Background())
	results := make(chan CleanupResult, 4)
	errors := make(chan error, 1)
	go func() {
		errors <- server.RunCleanupLoop(ctx, 20*time.Millisecond, func(result CleanupResult, err error) {
			if err != nil {
				return
			}
			results <- result
		})
	}()

	var startup CleanupResult
	select {
	case startup = <-results:
	case <-time.After(time.Second):
		cancel()
		t.Fatal("startup cleanup did not run")
	}
	if startup.DeletedMessages != 1 {
		cancel()
		t.Fatalf("startup cleanup result = %+v, want one deleted message", startup)
	}
	select {
	case periodic := <-results:
		if periodic.DeletedMessages != 0 {
			cancel()
			t.Fatalf("periodic cleanup result = %+v, want no remaining message", periodic)
		}
	case <-time.After(time.Second):
		cancel()
		t.Fatal("periodic cleanup did not run")
	}
	cancel()
	select {
	case err := <-errors:
		if err != nil {
			t.Fatalf("RunCleanupLoop() error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cleanup loop did not stop after cancellation")
	}
}

func TestWatchedRequiresRecipientDeliveryAndDeletedRelayBlob(t *testing.T) {
	database, relay, _ := newHardeningTestRelay(t, Options{RetentionDays: 7})
	alice, bob, message := createPendingTestMessage(t, relay.URL)
	patchWatched(t, relay.URL, alice.BearerToken, message.ID, http.StatusForbidden, nil)
	patchWatched(t, relay.URL, bob.BearerToken, message.ID, http.StatusConflict, nil)

	acknowledgeDelivered(t, relay.URL, bob.BearerToken, message.ID)
	patchWatched(t, relay.URL, alice.BearerToken, message.ID, http.StatusForbidden, nil)
	var watched messageResponse
	patchWatched(t, relay.URL, bob.BearerToken, message.ID, http.StatusOK, &watched)
	if watched.Status != "watched" || watched.EncryptedBlobPath != "" {
		t.Fatalf("watched response = %+v, want watched with no relay blob", watched)
	}
	var firstWatchedAt string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT watched_at FROM messages WHERE id = ?`,
		message.ID,
	).Scan(&firstWatchedAt); err != nil {
		t.Fatalf("read first watched timestamp: %v", err)
	}
	patchWatched(t, relay.URL, bob.BearerToken, message.ID, http.StatusOK, nil)
	var secondWatchedAt string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT watched_at FROM messages WHERE id = ?`,
		message.ID,
	).Scan(&secondWatchedAt); err != nil {
		t.Fatalf("read idempotent watched timestamp: %v", err)
	}
	if firstWatchedAt == "" || secondWatchedAt != firstWatchedAt {
		t.Fatalf("watched timestamps = first %q second %q, want one preserved timestamp", firstWatchedAt, secondWatchedAt)
	}

	repeatedDelivery := acknowledgeDelivered(t, relay.URL, bob.BearerToken, message.ID)
	if repeatedDelivery.Status != "watched" || !repeatedDelivery.BlobDeleted {
		t.Fatalf("delivery acknowledgement after watched = %+v, want watched with deleted blob", repeatedDelivery)
	}
	var statusAfterRepeatedDelivery string
	var watchedAtAfterRepeatedDelivery string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT status, watched_at FROM messages WHERE id = ?`,
		message.ID,
	).Scan(&statusAfterRepeatedDelivery, &watchedAtAfterRepeatedDelivery); err != nil {
		t.Fatalf("read watched message after repeated delivery: %v", err)
	}
	if statusAfterRepeatedDelivery != "watched" || watchedAtAfterRepeatedDelivery != firstWatchedAt {
		t.Fatalf(
			"message after repeated delivery = status %q watched_at %q, want watched and %q",
			statusAfterRepeatedDelivery,
			watchedAtAfterRepeatedDelivery,
			firstWatchedAt,
		)
	}
}

func TestPendingBlobCleanupWaitsForGraceAndPreservesReferencedCiphertext(t *testing.T) {
	database, relay, blobStore := newHardeningTestRelay(t, Options{RetentionDays: 7})
	alice, bob, message := createPendingTestMessage(t, relay.URL)
	var successfulUploadMarkers int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM pending_blob_writes`,
	).Scan(&successfulUploadMarkers); err != nil {
		t.Fatalf("count successful-upload pending markers: %v", err)
	}
	if successfulUploadMarkers != 0 {
		t.Fatalf("successful upload pending marker count = %d, want 0", successfulUploadMarkers)
	}
	baseTime := time.Date(2026, time.August, 9, 12, 0, 0, 0, time.UTC)
	const pendingPath = "messages/interrupted-upload.blob"
	if _, err := database.ExecContext(
		context.Background(),
		`INSERT INTO pending_blob_writes(
			blob_path, sender_user_id, recipient_user_id, blob_size, state, created_at
		 ) VALUES (?, ?, ?, ?, 'pending', ?)`,
		pendingPath,
		alice.User.ID,
		bob.User.ID,
		int64(len("partial ciphertext")),
		baseTime.Format(time.RFC3339),
	); err != nil {
		t.Fatalf("register interrupted upload: %v", err)
	}
	if err := blobStore.Write(context.Background(), pendingPath, strings.NewReader("partial ciphertext")); err != nil {
		t.Fatalf("write interrupted upload: %v", err)
	}
	// This inconsistent marker exercises the fail-safe branch: reconciliation
	// may clear the marker but must never delete a message-referenced blob.
	if _, err := database.ExecContext(
		context.Background(),
		`INSERT INTO pending_blob_writes(
			blob_path, sender_user_id, recipient_user_id, blob_size, state, created_at
		 ) VALUES (?, ?, ?, ?, 'cleaning', ?)`,
		message.EncryptedBlobPath,
		alice.User.ID,
		bob.User.ID,
		message.BlobSize,
		baseTime.Format(time.RFC3339),
	); err != nil {
		t.Fatalf("register referenced cleanup marker: %v", err)
	}

	cleanupServer := NewWithOptions(database, blobStore, Options{RetentionDays: 7})
	cleanupServer.now = func() time.Time { return baseTime.Add(pendingBlobCleanupGracePeriod - time.Second) }
	result, err := cleanupServer.CleanupExpired(context.Background())
	if err != nil || result.DeletedPendingBlobs != 0 || result.FailedPendingBlobs != 0 {
		t.Fatalf("pre-grace pending cleanup result = %+v, error = %v", result, err)
	}
	if reader, err := blobStore.Read(context.Background(), pendingPath); err != nil {
		t.Fatalf("pre-grace pending blob was deleted: %v", err)
	} else {
		reader.Close()
	}
	if status := downloadMessageStatus(t, relay.URL, bob.BearerToken, message.ID); status != http.StatusOK {
		t.Fatalf("referenced blob status after marker reconciliation = %d, want %d", status, http.StatusOK)
	}

	cleanupServer.now = func() time.Time { return baseTime.Add(pendingBlobCleanupGracePeriod) }
	result, err = cleanupServer.CleanupExpired(context.Background())
	if err != nil || result.DeletedPendingBlobs != 1 || result.FailedPendingBlobs != 0 {
		t.Fatalf("post-grace pending cleanup result = %+v, error = %v", result, err)
	}
	if reader, err := blobStore.Read(context.Background(), pendingPath); err == nil {
		reader.Close()
		t.Fatal("post-grace pending ciphertext remained")
	}
	if status := downloadMessageStatus(t, relay.URL, bob.BearerToken, message.ID); status != http.StatusOK {
		t.Fatalf("referenced blob status after pending deletion = %d, want %d", status, http.StatusOK)
	}
	var markerCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM pending_blob_writes`,
	).Scan(&markerCount); err != nil {
		t.Fatalf("count pending markers: %v", err)
	}
	if markerCount != 0 {
		t.Fatalf("pending marker count = %d, want 0", markerCount)
	}
}

func TestPendingBlobCleanupRetriesFailedDeletion(t *testing.T) {
	database, _, blobStore := newHardeningTestRelay(t, Options{RetentionDays: 7})
	baseTime := time.Date(2026, time.August, 9, 12, 0, 0, 0, time.UTC)
	const pendingPath = "messages/retry-interrupted-upload.blob"
	if _, err := database.ExecContext(
		context.Background(),
		`INSERT INTO pending_blob_writes(
			blob_path, sender_user_id, recipient_user_id, blob_size, state, created_at
		 ) VALUES (?, 'sender', 'recipient', ?, 'pending', ?)`,
		pendingPath,
		int64(len("retry ciphertext")),
		baseTime.Format(time.RFC3339),
	); err != nil {
		t.Fatalf("register retry upload: %v", err)
	}
	if err := blobStore.Write(context.Background(), pendingPath, strings.NewReader("retry ciphertext")); err != nil {
		t.Fatalf("write retry upload: %v", err)
	}

	cleanupServer := NewWithOptions(database, blobStore, Options{RetentionDays: 7})
	cleanupServer.now = func() time.Time { return baseTime.Add(pendingBlobCleanupGracePeriod) }
	blobStore.setFailDeletes(true)
	result, err := cleanupServer.CleanupExpired(context.Background())
	if err == nil || result.DeletedPendingBlobs != 0 || result.FailedPendingBlobs != 1 {
		t.Fatalf("failed pending cleanup result = %+v, error = %v", result, err)
	}
	var state string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT state FROM pending_blob_writes WHERE blob_path = ?`,
		pendingPath,
	).Scan(&state); err != nil {
		t.Fatalf("read failed cleanup state: %v", err)
	}
	if state != "cleaning" {
		t.Fatalf("failed cleanup state = %q, want cleaning", state)
	}

	blobStore.setFailDeletes(false)
	result, err = cleanupServer.CleanupExpired(context.Background())
	if err != nil || result.DeletedPendingBlobs != 1 || result.FailedPendingBlobs != 0 {
		t.Fatalf("retried pending cleanup result = %+v, error = %v", result, err)
	}
}

func TestUploadEnforcesSizeAndPendingAccountQuotaByBlobPresence(t *testing.T) {
	database, relay, _ := newHardeningTestRelay(t, Options{
		RetentionDays:                7,
		MaxUploadBytes:               8,
		MaxPendingBytesPerAccount:    10,
		MaxPendingMessagesPerAccount: 10,
		MaxPendingBytesTotal:         20,
	})
	alice := registerTestDevice(t, relay.URL, "quota-alice")
	bob := registerTestDevice(t, relay.URL, "quota-bob")
	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)
	envelope := validTestEnvelope(t, alice.Device.ID, bob.Device.ID)

	first := uploadTestMessage(t, relay.URL, alice.BearerToken, bob.User.ID, bob.Device.ID, envelope, []byte("123456"))
	if first.BlobSize != 6 {
		t.Fatalf("first blob size = %d, want 6", first.BlobSize)
	}
	if _, err := database.ExecContext(
		context.Background(),
		`UPDATE messages SET status = 'watched' WHERE id = ?`,
		first.ID,
	); err != nil {
		t.Fatalf("set legacy watched status with retained blob: %v", err)
	}
	if status := uploadTestMessageStatus(t, relay.URL, alice.BearerToken, bob.User.ID, bob.Device.ID, envelope, []byte("abcdef")); status != http.StatusInsufficientStorage {
		t.Fatalf("quota upload status = %d, want %d", status, http.StatusInsufficientStorage)
	}
	if status := uploadTestMessageStatus(t, relay.URL, alice.BearerToken, bob.User.ID, bob.Device.ID, envelope, []byte("123456789")); status != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized blob status = %d, want %d", status, http.StatusRequestEntityTooLarge)
	}
}

func TestPendingBlobWritesCountAgainstAccountQuota(t *testing.T) {
	database, relay, _ := newHardeningTestRelay(t, Options{
		RetentionDays:                7,
		MaxUploadBytes:               8,
		MaxPendingBytesPerAccount:    10,
		MaxPendingMessagesPerAccount: 1,
		MaxPendingBytesTotal:         20,
	})
	alice := registerTestDevice(t, relay.URL, "pending-quota-alice")
	bob := registerTestDevice(t, relay.URL, "pending-quota-bob")
	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)
	if _, err := database.ExecContext(
		context.Background(),
		`INSERT INTO pending_blob_writes(
			blob_path, sender_user_id, recipient_user_id, blob_size, state, created_at
		 ) VALUES ('messages/pending-quota.blob', ?, ?, 6, 'pending', ?)`,
		alice.User.ID,
		bob.User.ID,
		time.Now().UTC().Format(time.RFC3339),
	); err != nil {
		t.Fatalf("insert pending quota record: %v", err)
	}

	status := uploadTestMessageStatus(
		t,
		relay.URL,
		alice.BearerToken,
		bob.User.ID,
		bob.Device.ID,
		validTestEnvelope(t, alice.Device.ID, bob.Device.ID),
		[]byte("x"),
	)
	if status != http.StatusInsufficientStorage {
		t.Fatalf("upload with pending ownership record status = %d, want %d", status, http.StatusInsufficientStorage)
	}
}

func patchWatched(t *testing.T, baseURL string, token string, messageID string, wantStatus int, target any) {
	t.Helper()
	body, err := json.Marshal(updateStatusRequest{Status: "watched"})
	if err != nil {
		t.Fatalf("marshal watched update: %v", err)
	}
	request := authedRequest(
		t,
		http.MethodPatch,
		baseURL+"/messages/"+messageID+"/status",
		token,
		bytes.NewReader(body),
	)
	request.Header.Set("Content-Type", "application/json")
	doRequest(t, request, wantStatus, target)
}

func newHardeningTestRelay(t *testing.T, options Options) (*sql.DB, *httptest.Server, *failingDeleteStore) {
	t.Helper()
	database, err := db.Open(context.Background(), ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })
	localStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}
	blobStore := &failingDeleteStore{Store: localStore}
	relay := httptest.NewServer(NewWithOptions(database, blobStore, options).Handler())
	t.Cleanup(relay.Close)
	return database, relay, blobStore
}

func createPendingTestMessage(t *testing.T, baseURL string) (authSessionResponse, authSessionResponse, messageResponse) {
	t.Helper()
	alice := registerTestDevice(t, baseURL, "pending-alice")
	bob := registerTestDevice(t, baseURL, "pending-bob")
	invite := createInvite(t, baseURL, alice.BearerToken)
	_ = acceptInvite(t, baseURL, bob.BearerToken, invite.Code)
	message := uploadTestMessage(
		t,
		baseURL,
		alice.BearerToken,
		bob.User.ID,
		bob.Device.ID,
		validTestEnvelope(t, alice.Device.ID, bob.Device.ID),
		[]byte("pending ciphertext"),
	)
	return alice, bob, message
}
