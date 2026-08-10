package api

import (
	"context"
	"fmt"
)

type pendingQuotaError struct {
	message string
}

func (e *pendingQuotaError) Error() string {
	return e.message
}

func (s *Server) checkPendingQuota(ctx context.Context, senderID string, recipientID string, incomingBytes int64) error {
	var totalBytes int64
	if err := s.db.QueryRowContext(
		ctx,
		`SELECT COALESCE(SUM(blob_size), 0)
		   FROM (
			SELECT blob_size FROM messages WHERE encrypted_blob_path <> ''
			UNION ALL
			SELECT blob_size FROM pending_blob_writes
		   )`,
	).Scan(&totalBytes); err != nil {
		return fmt.Errorf("read global pending storage: %w", err)
	}
	if incomingBytes > s.options.MaxPendingBytesTotal-totalBytes {
		return &pendingQuotaError{message: "relay pending-storage quota is full; retry after messages are delivered or expire"}
	}

	for _, accountID := range []string{senderID, recipientID} {
		var accountBytes int64
		var accountMessages int
		if err := s.db.QueryRowContext(
			ctx,
			`SELECT COALESCE(SUM(blob_size), 0), COUNT(*)
			   FROM (
				SELECT blob_size
				  FROM messages
				 WHERE encrypted_blob_path <> ''
				   AND (sender_user_id = ? OR recipient_user_id = ?)
				UNION ALL
				SELECT blob_size
				  FROM pending_blob_writes
				 WHERE sender_user_id = ? OR recipient_user_id = ?
			   )`,
			accountID,
			accountID,
			accountID,
			accountID,
		).Scan(&accountBytes, &accountMessages); err != nil {
			return fmt.Errorf("read account pending storage: %w", err)
		}
		if accountMessages >= s.options.MaxPendingMessagesPerAccount {
			return &pendingQuotaError{message: "account pending-message quota is full; retry after messages are delivered or expire"}
		}
		if incomingBytes > s.options.MaxPendingBytesPerAccount-accountBytes {
			return &pendingQuotaError{message: "account pending-storage quota is full; retry after messages are delivered or expire"}
		}
	}
	return nil
}
