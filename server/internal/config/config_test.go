package config

import (
	"testing"
	"time"
)

func TestLoadUsesPublicReleaseHardeningDefaults(t *testing.T) {
	clearConfigEnvironment(t)
	config, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if config.ChallengeTTL != 5*time.Minute || config.SessionTTL != 30*24*time.Hour {
		t.Fatalf("auth TTLs = (%s, %s), want (5m, 720h)", config.ChallengeTTL, config.SessionTTL)
	}
	if config.MaxUploadBytes != 64<<20 || config.MaxPendingBytesPerAccount != 256<<20 || config.MaxPendingBytesTotal != 2<<30 {
		t.Fatalf(
			"storage limits = (%d, %d, %d), want (%d, %d, %d)",
			config.MaxUploadBytes,
			config.MaxPendingBytesPerAccount,
			config.MaxPendingBytesTotal,
			64<<20,
			256<<20,
			2<<30,
		)
	}
	if config.TrustProxyHeaders {
		t.Fatal("TrustProxyHeaders default = true, want false")
	}
	if config.InviteRatePerAccount != 10 || config.ReportRatePerAccount != 20 ||
		config.MaxOutstandingInvitesPerAccount != 5 || config.MaxInviteRecordsPerAccount != 1_000 ||
		config.MaxInviteRecordsTotal != 100_000 || config.MaxReportRecordsPerAccount != 1_000 ||
		config.MaxReportRecordsTotal != 100_000 {
		t.Fatalf("invite/report defaults = %+v", config)
	}
}

func TestLoadRejectsIncoherentPendingQuota(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("MAX_UPLOAD_BYTES", "1024")
	t.Setenv("MAX_PENDING_BYTES_PER_ACCOUNT", "512")
	if _, err := Load(); err == nil {
		t.Fatal("Load() error = nil, want incoherent quota error")
	}
}

func TestLoadRejectsIncoherentInviteAndReportCaps(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("MAX_OUTSTANDING_INVITES_PER_ACCOUNT", "3")
	t.Setenv("MAX_INVITE_RECORDS_PER_ACCOUNT", "2")
	if _, err := Load(); err == nil {
		t.Fatal("Load() error = nil, want incoherent invite-cap error")
	}

	clearConfigEnvironment(t)
	t.Setenv("MAX_REPORT_RECORDS_PER_ACCOUNT", "10")
	t.Setenv("MAX_REPORT_RECORDS_TOTAL", "9")
	if _, err := Load(); err == nil {
		t.Fatal("Load() error = nil, want incoherent report-cap error")
	}
}

func TestLoadReadsHardeningOverrides(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("AUTH_CHALLENGE_TTL_SECONDS", "120")
	t.Setenv("SESSION_TTL_HOURS", "48")
	t.Setenv("MAX_UPLOAD_BYTES", "1024")
	t.Setenv("MAX_PENDING_BYTES_PER_ACCOUNT", "4096")
	t.Setenv("MAX_PENDING_MESSAGES_PER_ACCOUNT", "3")
	t.Setenv("MAX_PENDING_BYTES_TOTAL", "8192")
	t.Setenv("REGISTRATION_RATE_PER_IP_HOUR", "2")
	t.Setenv("REGISTRATION_RATE_GLOBAL_HOUR", "20")
	t.Setenv("AUTH_RATE_PER_IP_15_MINUTES", "4")
	t.Setenv("AUTH_RATE_GLOBAL_15_MINUTES", "40")
	t.Setenv("UPLOAD_RATE_PER_ACCOUNT_HOUR", "6")
	t.Setenv("INVITE_RATE_PER_ACCOUNT_HOUR", "7")
	t.Setenv("REPORT_RATE_PER_ACCOUNT_HOUR", "8")
	t.Setenv("MAX_OUTSTANDING_INVITES_PER_ACCOUNT", "2")
	t.Setenv("MAX_INVITE_RECORDS_PER_ACCOUNT", "20")
	t.Setenv("MAX_INVITE_RECORDS_TOTAL", "200")
	t.Setenv("MAX_REPORT_RECORDS_PER_ACCOUNT", "30")
	t.Setenv("MAX_REPORT_RECORDS_TOTAL", "300")
	t.Setenv("TRUST_PROXY_HEADERS", "true")

	config, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if config.ChallengeTTL != 2*time.Minute || config.SessionTTL != 48*time.Hour {
		t.Fatalf("auth TTL overrides = (%s, %s)", config.ChallengeTTL, config.SessionTTL)
	}
	if config.MaxUploadBytes != 1024 || config.MaxPendingBytesPerAccount != 4096 ||
		config.MaxPendingMessagesPerAccount != 3 || config.MaxPendingBytesTotal != 8192 {
		t.Fatalf("quota overrides = %+v", config)
	}
	if config.RegistrationRatePerIP != 2 || config.RegistrationRateGlobal != 20 ||
		config.AuthRatePerIP != 4 || config.AuthRateGlobal != 40 || config.UploadRatePerAccount != 6 ||
		config.InviteRatePerAccount != 7 || config.ReportRatePerAccount != 8 {
		t.Fatalf("rate overrides = %+v", config)
	}
	if config.MaxOutstandingInvitesPerAccount != 2 || config.MaxInviteRecordsPerAccount != 20 ||
		config.MaxInviteRecordsTotal != 200 || config.MaxReportRecordsPerAccount != 30 ||
		config.MaxReportRecordsTotal != 300 {
		t.Fatalf("database cap overrides = %+v", config)
	}
	if !config.TrustProxyHeaders {
		t.Fatal("TrustProxyHeaders override = false, want true")
	}
}

func clearConfigEnvironment(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		"UNDELIVERED_RETENTION_DAYS", "SPEAKEASY_UNDELIVERED_RETENTION_DAYS",
		"AUTH_CHALLENGE_TTL_SECONDS", "SPEAKEASY_AUTH_CHALLENGE_TTL_SECONDS",
		"SESSION_TTL_HOURS", "SPEAKEASY_SESSION_TTL_HOURS",
		"MAX_UPLOAD_BYTES", "SPEAKEASY_MAX_UPLOAD_BYTES",
		"MAX_PENDING_BYTES_PER_ACCOUNT", "SPEAKEASY_MAX_PENDING_BYTES_PER_ACCOUNT",
		"MAX_PENDING_MESSAGES_PER_ACCOUNT", "SPEAKEASY_MAX_PENDING_MESSAGES_PER_ACCOUNT",
		"MAX_PENDING_BYTES_TOTAL", "SPEAKEASY_MAX_PENDING_BYTES_TOTAL",
		"REGISTRATION_RATE_PER_IP_HOUR", "SPEAKEASY_REGISTRATION_RATE_PER_IP_HOUR",
		"REGISTRATION_RATE_GLOBAL_HOUR", "SPEAKEASY_REGISTRATION_RATE_GLOBAL_HOUR",
		"AUTH_RATE_PER_IP_15_MINUTES", "SPEAKEASY_AUTH_RATE_PER_IP_15_MINUTES",
		"AUTH_RATE_GLOBAL_15_MINUTES", "SPEAKEASY_AUTH_RATE_GLOBAL_15_MINUTES",
		"UPLOAD_RATE_PER_ACCOUNT_HOUR", "SPEAKEASY_UPLOAD_RATE_PER_ACCOUNT_HOUR",
		"INVITE_RATE_PER_ACCOUNT_HOUR", "SPEAKEASY_INVITE_RATE_PER_ACCOUNT_HOUR",
		"REPORT_RATE_PER_ACCOUNT_HOUR", "SPEAKEASY_REPORT_RATE_PER_ACCOUNT_HOUR",
		"MAX_OUTSTANDING_INVITES_PER_ACCOUNT", "SPEAKEASY_MAX_OUTSTANDING_INVITES_PER_ACCOUNT",
		"MAX_INVITE_RECORDS_PER_ACCOUNT", "SPEAKEASY_MAX_INVITE_RECORDS_PER_ACCOUNT",
		"MAX_INVITE_RECORDS_TOTAL", "SPEAKEASY_MAX_INVITE_RECORDS_TOTAL",
		"MAX_REPORT_RECORDS_PER_ACCOUNT", "SPEAKEASY_MAX_REPORT_RECORDS_PER_ACCOUNT",
		"MAX_REPORT_RECORDS_TOTAL", "SPEAKEASY_MAX_REPORT_RECORDS_TOTAL",
		"TRUST_PROXY_HEADERS", "SPEAKEASY_TRUST_PROXY_HEADERS",
	} {
		t.Setenv(name, "")
	}
}
