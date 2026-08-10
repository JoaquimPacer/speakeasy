package api

import (
	"context"
	"errors"
	"fmt"
	"time"
)

type CleanupResult struct {
	DeletedMessages     int
	FailedMessages      int
	DeletedPendingBlobs int
	FailedPendingBlobs  int
	DeletedSessions     int64
	DeletedChallenges   int64
}

const pendingBlobCleanupGracePeriod = 15 * time.Minute

type expiredMessage struct {
	id       string
	blobPath string
}

// CleanupExpired removes relay ciphertext and message metadata after the
// configured retention deadline. Failed blob deletions keep their database
// path and an expired tombstone so the next run can retry safely.
func (s *Server) CleanupExpired(ctx context.Context) (CleanupResult, error) {
	s.blobMutationMu.Lock()
	defer s.blobMutationMu.Unlock()

	now := s.now().UTC().Truncate(time.Second)
	nowText := now.Format(time.RFC3339)
	if _, err := s.db.ExecContext(
		ctx,
		`UPDATE messages
		    SET status = 'expired', updated_at = ?
		  WHERE encrypted_blob_path <> '' AND expires_at <= ?`,
		nowText,
		nowText,
	); err != nil {
		return CleanupResult{}, fmt.Errorf("claim expired messages: %w", err)
	}

	rows, err := s.db.QueryContext(
		ctx,
		`SELECT id, encrypted_blob_path
		   FROM messages
		  WHERE encrypted_blob_path <> '' AND expires_at <= ?
		  ORDER BY expires_at ASC`,
		nowText,
	)
	if err != nil {
		return CleanupResult{}, fmt.Errorf("list expired messages: %w", err)
	}
	var expired []expiredMessage
	for rows.Next() {
		var message expiredMessage
		if err := rows.Scan(&message.id, &message.blobPath); err != nil {
			rows.Close()
			return CleanupResult{}, fmt.Errorf("scan expired message: %w", err)
		}
		expired = append(expired, message)
	}
	if err := rows.Close(); err != nil {
		return CleanupResult{}, fmt.Errorf("close expired messages: %w", err)
	}
	if err := rows.Err(); err != nil {
		return CleanupResult{}, fmt.Errorf("iterate expired messages: %w", err)
	}

	result := CleanupResult{}
	var cleanupErrors []error
	for _, message := range expired {
		if message.blobPath != "" {
			if err := s.store.Delete(ctx, message.blobPath); err != nil {
				result.FailedMessages++
				cleanupErrors = append(cleanupErrors, fmt.Errorf("delete expired message %s blob: %w", message.id, err))
				continue
			}
		}
		deleteResult, err := s.db.ExecContext(
			ctx,
			`DELETE FROM messages
			  WHERE id = ? AND status = 'expired' AND encrypted_blob_path = ? AND expires_at <= ?`,
			message.id,
			message.blobPath,
			nowText,
		)
		if err != nil {
			result.FailedMessages++
			cleanupErrors = append(cleanupErrors, fmt.Errorf("delete expired message %s row: %w", message.id, err))
			continue
		}
		deleted, err := deleteResult.RowsAffected()
		if err != nil || deleted != 1 {
			result.FailedMessages++
			cleanupErrors = append(cleanupErrors, fmt.Errorf("delete expired message %s row: concurrent change", message.id))
			continue
		}
		result.DeletedMessages++
	}

	pendingDeleted, pendingFailed, pendingErr := s.cleanupPendingBlobWrites(ctx, now)
	result.DeletedPendingBlobs = pendingDeleted
	result.FailedPendingBlobs = pendingFailed
	if pendingErr != nil {
		cleanupErrors = append(cleanupErrors, pendingErr)
	}

	if sessions, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE expires_at <= ?`, nowText); err != nil {
		cleanupErrors = append(cleanupErrors, fmt.Errorf("delete expired sessions: %w", err))
	} else {
		result.DeletedSessions, _ = sessions.RowsAffected()
	}
	if challenges, err := s.db.ExecContext(
		ctx,
		`DELETE FROM auth_challenges WHERE expires_at <= ? OR consumed_at IS NOT NULL`,
		nowText,
	); err != nil {
		cleanupErrors = append(cleanupErrors, fmt.Errorf("delete stale auth challenges: %w", err))
	} else {
		result.DeletedChallenges, _ = challenges.RowsAffected()
	}

	return result, errors.Join(cleanupErrors...)
}

type pendingBlobWrite struct {
	path  string
	state string
}

// cleanupPendingBlobWrites removes only paths durably registered before an
// upload began. A conditional state claim is mutually exclusive with the
// transaction that promotes a completed upload into messages, so cleanup never
// deletes a blob that that transaction can reference. Cleaning records survive
// failures and process crashes for an idempotent retry.
func (s *Server) cleanupPendingBlobWrites(ctx context.Context, now time.Time) (int, int, error) {
	cutoff := now.Add(-pendingBlobCleanupGracePeriod).Format(time.RFC3339)
	rows, err := s.db.QueryContext(
		ctx,
		`SELECT blob_path, state
		   FROM pending_blob_writes
		  WHERE state = 'cleaning' OR created_at <= ?
		  ORDER BY created_at ASC`,
		cutoff,
	)
	if err != nil {
		return 0, 0, fmt.Errorf("list pending blob writes: %w", err)
	}
	var pending []pendingBlobWrite
	for rows.Next() {
		var blob pendingBlobWrite
		if err := rows.Scan(&blob.path, &blob.state); err != nil {
			rows.Close()
			return 0, 0, fmt.Errorf("scan pending blob write: %w", err)
		}
		pending = append(pending, blob)
	}
	if err := rows.Close(); err != nil {
		return 0, 0, fmt.Errorf("close pending blob writes: %w", err)
	}
	if err := rows.Err(); err != nil {
		return 0, 0, fmt.Errorf("iterate pending blob writes: %w", err)
	}

	deleted := 0
	failed := 0
	var cleanupErrors []error
	for _, blob := range pending {
		var referenced int
		if err := s.db.QueryRowContext(
			ctx,
			`SELECT COUNT(*) FROM messages WHERE encrypted_blob_path = ?`,
			blob.path,
		).Scan(&referenced); err != nil {
			failed++
			cleanupErrors = append(cleanupErrors, fmt.Errorf("check pending blob %q reference: %w", blob.path, err))
			continue
		}
		if referenced != 0 {
			if _, err := s.db.ExecContext(ctx, `DELETE FROM pending_blob_writes WHERE blob_path = ?`, blob.path); err != nil {
				failed++
				cleanupErrors = append(cleanupErrors, fmt.Errorf("clear referenced pending blob %q: %w", blob.path, err))
			}
			continue
		}

		if blob.state == "pending" {
			claim, err := s.db.ExecContext(
				ctx,
				`UPDATE pending_blob_writes
				    SET state = 'cleaning'
				  WHERE blob_path = ? AND state = 'pending' AND created_at <= ?
				    AND NOT EXISTS (
					SELECT 1 FROM messages WHERE encrypted_blob_path = pending_blob_writes.blob_path
				    )`,
				blob.path,
				cutoff,
			)
			if err != nil {
				failed++
				cleanupErrors = append(cleanupErrors, fmt.Errorf("claim pending blob %q cleanup: %w", blob.path, err))
				continue
			}
			claimed, err := claim.RowsAffected()
			if err != nil {
				failed++
				cleanupErrors = append(cleanupErrors, fmt.Errorf("read pending blob %q cleanup claim: %w", blob.path, err))
				continue
			}
			if claimed != 1 {
				continue
			}
		}

		if err := s.store.Delete(ctx, blob.path); err != nil {
			failed++
			cleanupErrors = append(cleanupErrors, fmt.Errorf("delete pending blob %q: %w", blob.path, err))
			continue
		}
		remove, err := s.db.ExecContext(
			ctx,
			`DELETE FROM pending_blob_writes
			  WHERE blob_path = ? AND state = 'cleaning'
			    AND NOT EXISTS (
				SELECT 1 FROM messages WHERE encrypted_blob_path = pending_blob_writes.blob_path
			    )`,
			blob.path,
		)
		if err != nil {
			failed++
			cleanupErrors = append(cleanupErrors, fmt.Errorf("clear pending blob %q cleanup record: %w", blob.path, err))
			continue
		}
		removed, err := remove.RowsAffected()
		if err != nil || removed != 1 {
			failed++
			cleanupErrors = append(cleanupErrors, fmt.Errorf("clear pending blob %q cleanup record: concurrent ownership change", blob.path))
			continue
		}
		deleted++
	}
	return deleted, failed, errors.Join(cleanupErrors...)
}

// RunCleanupLoop runs retention cleanup immediately at process startup and at
// each interval until ctx is cancelled. Cleanup errors are reported and then
// retried on the next tick instead of stopping retention enforcement.
func (s *Server) RunCleanupLoop(
	ctx context.Context,
	interval time.Duration,
	report func(CleanupResult, error),
) error {
	if interval <= 0 {
		return fmt.Errorf("cleanup interval must be greater than zero")
	}
	run := func() {
		result, err := s.CleanupExpired(ctx)
		if report != nil {
			report(result, err)
		}
	}

	if err := ctx.Err(); err != nil {
		return nil
	}
	run()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			run()
		}
	}
}
