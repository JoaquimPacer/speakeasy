package db

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	_ "modernc.org/sqlite"
)

func Open(ctx context.Context, path string) (*sql.DB, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("database path is required")
	}
	if err := ensureParentDir(path); err != nil {
		return nil, err
	}

	database, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	database.SetMaxOpenConns(1)
	database.SetMaxIdleConns(1)

	if err := configure(ctx, database); err != nil {
		database.Close()
		return nil, err
	}
	if err := migrate(ctx, database); err != nil {
		database.Close()
		return nil, err
	}
	if err := database.PingContext(ctx); err != nil {
		database.Close()
		return nil, err
	}

	return database, nil
}

func ensureParentDir(path string) error {
	if path == ":memory:" || strings.HasPrefix(path, "file:") {
		return nil
	}

	dir := filepath.Dir(path)
	if dir == "." || dir == "" {
		return nil
	}

	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create database directory %q: %w", dir, err)
	}
	return nil
}

func configure(ctx context.Context, database *sql.DB) error {
	for _, statement := range []string{
		"PRAGMA foreign_keys = ON",
		"PRAGMA busy_timeout = 5000",
		"PRAGMA journal_mode = WAL",
		"PRAGMA synchronous = NORMAL",
	} {
		if _, err := database.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("configure sqlite: %w", err)
		}
	}
	return nil
}

func migrate(ctx context.Context, database *sql.DB) error {
	for _, statement := range schemaStatements {
		if _, err := database.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("apply schema: %w", err)
		}
	}
	return nil
}

var schemaStatements = []string{
	`CREATE TABLE IF NOT EXISTS schema_migrations (
		version INTEGER PRIMARY KEY,
		applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
	)`,
	`CREATE TABLE IF NOT EXISTS users (
		id TEXT PRIMARY KEY,
		username TEXT NOT NULL UNIQUE,
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
		updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
	)`,
	`CREATE TABLE IF NOT EXISTS devices (
		id TEXT PRIMARY KEY,
		user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		name TEXT NOT NULL DEFAULT '',
		encryption_public_key BLOB NOT NULL CHECK (length(encryption_public_key) > 0),
		signing_public_key BLOB NOT NULL CHECK (length(signing_public_key) > 0),
		apns_token TEXT,
		last_seen_at TEXT,
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
		updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
		UNIQUE (user_id, encryption_public_key),
		UNIQUE (user_id, signing_public_key)
	)`,
	`CREATE TABLE IF NOT EXISTS auth_challenges (
		id TEXT PRIMARY KEY,
		device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
		challenge BLOB NOT NULL CHECK (length(challenge) > 0),
		expires_at TEXT NOT NULL,
		consumed_at TEXT,
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
	)`,
	`CREATE TABLE IF NOT EXISTS sessions (
		token TEXT PRIMARY KEY,
		user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
		expires_at TEXT,
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
	)`,
	`CREATE TABLE IF NOT EXISTS contacts (
		user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		contact_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		nickname TEXT,
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
		PRIMARY KEY (user_id, contact_user_id),
		CHECK (user_id <> contact_user_id)
	)`,
	`CREATE TABLE IF NOT EXISTS invites (
		id TEXT PRIMARY KEY,
		code TEXT NOT NULL UNIQUE,
		inviter_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		inviter_device_id TEXT REFERENCES devices(id) ON DELETE SET NULL,
		status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'revoked', 'expired')),
		accepted_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
		accepted_at TEXT,
		expires_at TEXT NOT NULL,
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
	)`,
	`CREATE TABLE IF NOT EXISTS messages (
		id TEXT PRIMARY KEY,
		sender_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		sender_device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
		recipient_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		recipient_device_id TEXT REFERENCES devices(id) ON DELETE SET NULL,
		envelope_json TEXT NOT NULL,
		encrypted_blob_path TEXT NOT NULL,
		blob_size INTEGER NOT NULL CHECK (blob_size >= 0),
		status TEXT NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'delivered', 'watched', 'expired', 'deleted')),
		delivered_at TEXT,
		watched_at TEXT,
		blob_deleted_at TEXT,
		expires_at TEXT NOT NULL,
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
		updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
	)`,
	`CREATE TABLE IF NOT EXISTS reports (
		id TEXT PRIMARY KEY,
		reporter_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		reported_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
		message_id TEXT REFERENCES messages(id) ON DELETE SET NULL,
		reason TEXT NOT NULL,
		details TEXT NOT NULL DEFAULT '',
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
	)`,
	`CREATE TABLE IF NOT EXISTS blocks (
		blocker_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		blocked_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
		created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
		PRIMARY KEY (blocker_user_id, blocked_user_id),
		CHECK (blocker_user_id <> blocked_user_id)
	)`,
	`CREATE INDEX IF NOT EXISTS idx_devices_user_id ON devices(user_id)`,
	`CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id)`,
	`CREATE INDEX IF NOT EXISTS idx_contacts_contact_user_id ON contacts(contact_user_id)`,
	`CREATE INDEX IF NOT EXISTS idx_invites_inviter_user_id ON invites(inviter_user_id)`,
	`CREATE INDEX IF NOT EXISTS idx_invites_status_expires_at ON invites(status, expires_at)`,
	`CREATE INDEX IF NOT EXISTS idx_messages_recipient_status ON messages(recipient_user_id, status)`,
	`CREATE INDEX IF NOT EXISTS idx_messages_sender_created_at ON messages(sender_user_id, created_at)`,
	`CREATE INDEX IF NOT EXISTS idx_messages_expires_at ON messages(expires_at)`,
	`CREATE INDEX IF NOT EXISTS idx_reports_reporter_user_id ON reports(reporter_user_id)`,
	`CREATE INDEX IF NOT EXISTS idx_reports_reported_user_id ON reports(reported_user_id)`,
	`CREATE INDEX IF NOT EXISTS idx_blocks_blocked_user_id ON blocks(blocked_user_id)`,
	`INSERT OR IGNORE INTO schema_migrations(version) VALUES (1)`,
}
