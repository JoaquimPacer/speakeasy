package db

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"path/filepath"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestOpenUsesFullSynchronousModeForBlobOwnershipOrdering(t *testing.T) {
	database, err := Open(context.Background(), filepath.Join(t.TempDir(), "durability.db"))
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	defer database.Close()

	var synchronousMode int
	if err := database.QueryRowContext(context.Background(), `PRAGMA synchronous`).Scan(&synchronousMode); err != nil {
		t.Fatalf("read synchronous mode: %v", err)
	}
	if synchronousMode != 2 {
		t.Fatalf("PRAGMA synchronous = %d, want 2 (FULL)", synchronousMode)
	}
}

func TestOpenTransactionallyHashesLegacySessionsAndGrantsOneTimeGrace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	legacy, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open legacy database: %v", err)
	}
	for _, statement := range []string{
		`CREATE TABLE schema_migrations (
			version INTEGER PRIMARY KEY,
			applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
		)`,
		`CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE)`,
		`CREATE TABLE devices (id TEXT PRIMARY KEY, user_id TEXT NOT NULL)`,
		`CREATE TABLE sessions (
			token TEXT PRIMARY KEY,
			user_id TEXT NOT NULL,
			device_id TEXT NOT NULL,
			expires_at TEXT,
			created_at TEXT NOT NULL
		)`,
		`INSERT INTO schema_migrations(version) VALUES (1)`,
		`INSERT INTO users(id, username) VALUES ('user-1', 'legacy-user')`,
		`INSERT INTO devices(id, user_id) VALUES ('device-1', 'user-1')`,
		`INSERT INTO sessions(token, user_id, device_id, expires_at, created_at)
		 VALUES ('legacy-null-token', 'user-1', 'device-1', NULL, '2026-08-01T00:00:00Z')`,
		`INSERT INTO sessions(token, user_id, device_id, expires_at, created_at)
		 VALUES ('legacy-expiring-token', 'user-1', 'device-1', '2026-09-01T00:00:00Z', '2026-08-01T00:00:00Z')`,
	} {
		if _, err := legacy.ExecContext(context.Background(), statement); err != nil {
			legacy.Close()
			t.Fatalf("prepare legacy database: %v", err)
		}
	}
	if err := legacy.Close(); err != nil {
		t.Fatalf("close legacy database: %v", err)
	}

	startedAt := time.Now().UTC().Truncate(time.Second)
	database, err := Open(context.Background(), path)
	if err != nil {
		t.Fatalf("Open() migration error = %v", err)
	}
	finishedAt := time.Now().UTC().Truncate(time.Second)

	nullDigest := sha256.Sum256([]byte("legacy-null-token"))
	nullHash := hex.EncodeToString(nullDigest[:])
	var graceExpiryText string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT expires_at FROM sessions WHERE token = ?`,
		nullHash,
	).Scan(&graceExpiryText); err != nil {
		database.Close()
		t.Fatalf("read migrated NULL-expiry session: %v", err)
	}
	graceExpiry, err := time.Parse(time.RFC3339, graceExpiryText)
	if err != nil {
		database.Close()
		t.Fatalf("parse migrated grace expiry: %v", err)
	}
	if graceExpiry.Before(startedAt.Add(legacySessionGracePeriod)) || graceExpiry.After(finishedAt.Add(legacySessionGracePeriod)) {
		database.Close()
		t.Fatalf("legacy grace expiry = %s, want migration time plus %s", graceExpiry, legacySessionGracePeriod)
	}

	expiringDigest := sha256.Sum256([]byte("legacy-expiring-token"))
	expiringHash := hex.EncodeToString(expiringDigest[:])
	var preservedExpiry string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT expires_at FROM sessions WHERE token = ?`,
		expiringHash,
	).Scan(&preservedExpiry); err != nil {
		database.Close()
		t.Fatalf("read migrated expiring session: %v", err)
	}
	if preservedExpiry != "2026-09-01T00:00:00Z" {
		database.Close()
		t.Fatalf("preserved expiry = %q, want original expiry", preservedExpiry)
	}
	var rawCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM sessions WHERE token IN ('legacy-null-token', 'legacy-expiring-token')`,
	).Scan(&rawCount); err != nil {
		database.Close()
		t.Fatalf("count raw tokens: %v", err)
	}
	if rawCount != 0 {
		database.Close()
		t.Fatalf("raw legacy session count = %d, want 0", rawCount)
	}
	if err := database.Close(); err != nil {
		t.Fatalf("close migrated database: %v", err)
	}

	// Reopening must not hash the already-migrated digests again or extend the
	// bounded grace period.
	database, err = Open(context.Background(), path)
	if err != nil {
		t.Fatalf("second Open() migration error = %v", err)
	}
	defer database.Close()
	var reopenedExpiry string
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT expires_at FROM sessions WHERE token = ?`,
		nullHash,
	).Scan(&reopenedExpiry); err != nil {
		t.Fatalf("read idempotently migrated session: %v", err)
	}
	if reopenedExpiry != graceExpiryText {
		t.Fatalf("reopened grace expiry = %q, want unchanged %q", reopenedExpiry, graceExpiryText)
	}
	var migrationCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM schema_migrations WHERE version = 2`,
	).Scan(&migrationCount); err != nil {
		t.Fatalf("count token-hash migration marker: %v", err)
	}
	if migrationCount != 1 {
		t.Fatalf("token-hash migration marker count = %d, want 1", migrationCount)
	}
}

func TestLegacySessionHashMigrationRollsBackAllRowsOnFailure(t *testing.T) {
	database, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open migration rollback database: %v", err)
	}
	defer database.Close()
	database.SetMaxOpenConns(1)
	for _, statement := range []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY)`,
		`CREATE TABLE sessions (
			token TEXT PRIMARY KEY,
			user_id TEXT NOT NULL,
			device_id TEXT NOT NULL,
			expires_at TEXT,
			created_at TEXT NOT NULL
		)`,
		`INSERT INTO sessions(token, user_id, device_id, expires_at, created_at)
		 VALUES ('first-raw-token', 'user-1', 'device-1', NULL, '2026-08-01T00:00:00Z')`,
		`INSERT INTO sessions(token, user_id, device_id, expires_at, created_at)
		 VALUES ('second-raw-token', 'user-1', 'device-1', NULL, '2026-08-01T00:00:00Z')`,
		`CREATE TRIGGER reject_second_session_migration
		 BEFORE UPDATE ON sessions
		 WHEN OLD.token = 'second-raw-token'
		 BEGIN
			SELECT RAISE(ABORT, 'injected migration failure');
		 END`,
	} {
		if _, err := database.ExecContext(context.Background(), statement); err != nil {
			t.Fatalf("prepare migration rollback database: %v", err)
		}
	}

	err = hashLegacySessionTokens(
		context.Background(),
		database,
		time.Date(2026, time.August, 9, 12, 0, 0, 0, time.UTC),
	)
	if err == nil {
		t.Fatal("hashLegacySessionTokens() error = nil, want injected failure")
	}
	var rawCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM sessions WHERE token IN ('first-raw-token', 'second-raw-token') AND expires_at IS NULL`,
	).Scan(&rawCount); err != nil {
		t.Fatalf("count rolled-back raw sessions: %v", err)
	}
	if rawCount != 2 {
		t.Fatalf("rolled-back raw session count = %d, want 2", rawCount)
	}
	var migrationCount int
	if err := database.QueryRowContext(
		context.Background(),
		`SELECT COUNT(*) FROM schema_migrations WHERE version = 2`,
	).Scan(&migrationCount); err != nil {
		t.Fatalf("count rolled-back migration markers: %v", err)
	}
	if migrationCount != 0 {
		t.Fatalf("migration marker count after rollback = %d, want 0", migrationCount)
	}
}
