package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultAddress                      = ":8080"
	defaultDBPath                       = "data/speakeasy.db"
	defaultBlobStoragePath              = "data/blobs"
	defaultUndeliveredRetentionDays     = 7
	defaultChallengeTTLSeconds          = 300
	defaultSessionTTLHours              = 24 * 30
	defaultMaxUploadBytes               = int64(64 << 20)
	defaultMaxPendingBytesPerAccount    = int64(256 << 20)
	defaultMaxPendingMessagesPerAccount = 25
	defaultMaxPendingBytesTotal         = int64(2 << 30)
	defaultRegistrationRatePerIP        = 5
	defaultRegistrationRateGlobal       = 100
	defaultAuthRatePerIP                = 30
	defaultAuthRateGlobal               = 1000
	defaultUploadRatePerAccount         = 60
	defaultInviteRatePerAccount         = 10
	defaultReportRatePerAccount         = 20
	defaultMaxOutstandingInvites        = 5
	defaultMaxInviteRecordsPerAccount   = 1_000
	defaultMaxInviteRecordsTotal        = 100_000
	defaultMaxReportRecordsPerAccount   = 1_000
	defaultMaxReportRecordsTotal        = 100_000
)

type Config struct {
	Address                         string
	DBPath                          string
	BlobStoragePath                 string
	UndeliveredRetentionDays        int
	ChallengeTTL                    time.Duration
	SessionTTL                      time.Duration
	MaxUploadBytes                  int64
	MaxPendingBytesPerAccount       int64
	MaxPendingMessagesPerAccount    int
	MaxPendingBytesTotal            int64
	RegistrationRatePerIP           int
	RegistrationRateGlobal          int
	AuthRatePerIP                   int
	AuthRateGlobal                  int
	UploadRatePerAccount            int
	InviteRatePerAccount            int
	ReportRatePerAccount            int
	MaxOutstandingInvitesPerAccount int
	MaxInviteRecordsPerAccount      int
	MaxInviteRecordsTotal           int
	MaxReportRecordsPerAccount      int
	MaxReportRecordsTotal           int
	TrustProxyHeaders               bool
}

func Load() (Config, error) {
	retentionValue := envString(
		strconv.Itoa(defaultUndeliveredRetentionDays),
		"UNDELIVERED_RETENTION_DAYS",
		"SPEAKEASY_UNDELIVERED_RETENTION_DAYS",
	)

	retentionDays, err := strconv.Atoi(retentionValue)
	if err != nil {
		return Config{}, fmt.Errorf("UNDELIVERED_RETENTION_DAYS must be an integer: %w", err)
	}
	if retentionDays <= 0 {
		return Config{}, fmt.Errorf("UNDELIVERED_RETENTION_DAYS must be greater than zero")
	}

	challengeSeconds, err := envInt(defaultChallengeTTLSeconds, "AUTH_CHALLENGE_TTL_SECONDS", "SPEAKEASY_AUTH_CHALLENGE_TTL_SECONDS")
	if err != nil || challengeSeconds < 30 || challengeSeconds > 15*60 {
		return Config{}, fmt.Errorf("AUTH_CHALLENGE_TTL_SECONDS must be an integer from 30 through 900")
	}
	sessionHours, err := envInt(defaultSessionTTLHours, "SESSION_TTL_HOURS", "SPEAKEASY_SESSION_TTL_HOURS")
	if err != nil || sessionHours < 1 || sessionHours > 24*365 {
		return Config{}, fmt.Errorf("SESSION_TTL_HOURS must be an integer from 1 through 8760")
	}
	maxUploadBytes, err := envInt64(defaultMaxUploadBytes, "MAX_UPLOAD_BYTES", "SPEAKEASY_MAX_UPLOAD_BYTES")
	if err != nil || maxUploadBytes < 1 {
		return Config{}, fmt.Errorf("MAX_UPLOAD_BYTES must be a positive integer")
	}
	maxPendingBytesPerAccount, err := envInt64(defaultMaxPendingBytesPerAccount, "MAX_PENDING_BYTES_PER_ACCOUNT", "SPEAKEASY_MAX_PENDING_BYTES_PER_ACCOUNT")
	if err != nil || maxPendingBytesPerAccount < maxUploadBytes {
		return Config{}, fmt.Errorf("MAX_PENDING_BYTES_PER_ACCOUNT must be an integer at least MAX_UPLOAD_BYTES")
	}
	maxPendingMessagesPerAccount, err := envInt(defaultMaxPendingMessagesPerAccount, "MAX_PENDING_MESSAGES_PER_ACCOUNT", "SPEAKEASY_MAX_PENDING_MESSAGES_PER_ACCOUNT")
	if err != nil || maxPendingMessagesPerAccount < 1 {
		return Config{}, fmt.Errorf("MAX_PENDING_MESSAGES_PER_ACCOUNT must be a positive integer")
	}
	maxPendingBytesTotal, err := envInt64(defaultMaxPendingBytesTotal, "MAX_PENDING_BYTES_TOTAL", "SPEAKEASY_MAX_PENDING_BYTES_TOTAL")
	if err != nil || maxPendingBytesTotal < maxPendingBytesPerAccount {
		return Config{}, fmt.Errorf("MAX_PENDING_BYTES_TOTAL must be an integer at least MAX_PENDING_BYTES_PER_ACCOUNT")
	}
	registrationRatePerIP, err := envPositiveInt(defaultRegistrationRatePerIP, "REGISTRATION_RATE_PER_IP_HOUR", "SPEAKEASY_REGISTRATION_RATE_PER_IP_HOUR")
	if err != nil {
		return Config{}, err
	}
	registrationRateGlobal, err := envPositiveInt(defaultRegistrationRateGlobal, "REGISTRATION_RATE_GLOBAL_HOUR", "SPEAKEASY_REGISTRATION_RATE_GLOBAL_HOUR")
	if err != nil {
		return Config{}, err
	}
	authRatePerIP, err := envPositiveInt(defaultAuthRatePerIP, "AUTH_RATE_PER_IP_15_MINUTES", "SPEAKEASY_AUTH_RATE_PER_IP_15_MINUTES")
	if err != nil {
		return Config{}, err
	}
	authRateGlobal, err := envPositiveInt(defaultAuthRateGlobal, "AUTH_RATE_GLOBAL_15_MINUTES", "SPEAKEASY_AUTH_RATE_GLOBAL_15_MINUTES")
	if err != nil {
		return Config{}, err
	}
	uploadRatePerAccount, err := envPositiveInt(defaultUploadRatePerAccount, "UPLOAD_RATE_PER_ACCOUNT_HOUR", "SPEAKEASY_UPLOAD_RATE_PER_ACCOUNT_HOUR")
	if err != nil {
		return Config{}, err
	}
	inviteRatePerAccount, err := envPositiveInt(defaultInviteRatePerAccount, "INVITE_RATE_PER_ACCOUNT_HOUR", "SPEAKEASY_INVITE_RATE_PER_ACCOUNT_HOUR")
	if err != nil {
		return Config{}, err
	}
	reportRatePerAccount, err := envPositiveInt(defaultReportRatePerAccount, "REPORT_RATE_PER_ACCOUNT_HOUR", "SPEAKEASY_REPORT_RATE_PER_ACCOUNT_HOUR")
	if err != nil {
		return Config{}, err
	}
	maxOutstandingInvites, err := envPositiveInt(defaultMaxOutstandingInvites, "MAX_OUTSTANDING_INVITES_PER_ACCOUNT", "SPEAKEASY_MAX_OUTSTANDING_INVITES_PER_ACCOUNT")
	if err != nil {
		return Config{}, err
	}
	maxInviteRecordsPerAccount, err := envPositiveInt(defaultMaxInviteRecordsPerAccount, "MAX_INVITE_RECORDS_PER_ACCOUNT", "SPEAKEASY_MAX_INVITE_RECORDS_PER_ACCOUNT")
	if err != nil {
		return Config{}, err
	}
	maxInviteRecordsTotal, err := envPositiveInt(defaultMaxInviteRecordsTotal, "MAX_INVITE_RECORDS_TOTAL", "SPEAKEASY_MAX_INVITE_RECORDS_TOTAL")
	if err != nil {
		return Config{}, err
	}
	maxReportRecordsPerAccount, err := envPositiveInt(defaultMaxReportRecordsPerAccount, "MAX_REPORT_RECORDS_PER_ACCOUNT", "SPEAKEASY_MAX_REPORT_RECORDS_PER_ACCOUNT")
	if err != nil {
		return Config{}, err
	}
	maxReportRecordsTotal, err := envPositiveInt(defaultMaxReportRecordsTotal, "MAX_REPORT_RECORDS_TOTAL", "SPEAKEASY_MAX_REPORT_RECORDS_TOTAL")
	if err != nil {
		return Config{}, err
	}
	if maxInviteRecordsTotal < maxInviteRecordsPerAccount {
		return Config{}, fmt.Errorf("MAX_INVITE_RECORDS_TOTAL must be at least MAX_INVITE_RECORDS_PER_ACCOUNT")
	}
	if maxInviteRecordsPerAccount < maxOutstandingInvites {
		return Config{}, fmt.Errorf("MAX_INVITE_RECORDS_PER_ACCOUNT must be at least MAX_OUTSTANDING_INVITES_PER_ACCOUNT")
	}
	if maxReportRecordsTotal < maxReportRecordsPerAccount {
		return Config{}, fmt.Errorf("MAX_REPORT_RECORDS_TOTAL must be at least MAX_REPORT_RECORDS_PER_ACCOUNT")
	}
	trustProxyHeaders, err := envBool(false, "TRUST_PROXY_HEADERS", "SPEAKEASY_TRUST_PROXY_HEADERS")
	if err != nil {
		return Config{}, err
	}

	return Config{
		Address: envString(
			defaultAddress,
			"SPEAKEASY_ADDR",
			"ADDR",
		),
		DBPath: envString(
			defaultDBPath,
			"DB_PATH",
			"SPEAKEASY_DB_PATH",
		),
		BlobStoragePath: envString(
			defaultBlobStoragePath,
			"STORAGE_PATH",
			"BLOB_STORAGE_PATH",
			"SPEAKEASY_STORAGE_PATH",
		),
		UndeliveredRetentionDays:        retentionDays,
		ChallengeTTL:                    time.Duration(challengeSeconds) * time.Second,
		SessionTTL:                      time.Duration(sessionHours) * time.Hour,
		MaxUploadBytes:                  maxUploadBytes,
		MaxPendingBytesPerAccount:       maxPendingBytesPerAccount,
		MaxPendingMessagesPerAccount:    maxPendingMessagesPerAccount,
		MaxPendingBytesTotal:            maxPendingBytesTotal,
		RegistrationRatePerIP:           registrationRatePerIP,
		RegistrationRateGlobal:          registrationRateGlobal,
		AuthRatePerIP:                   authRatePerIP,
		AuthRateGlobal:                  authRateGlobal,
		UploadRatePerAccount:            uploadRatePerAccount,
		InviteRatePerAccount:            inviteRatePerAccount,
		ReportRatePerAccount:            reportRatePerAccount,
		MaxOutstandingInvitesPerAccount: maxOutstandingInvites,
		MaxInviteRecordsPerAccount:      maxInviteRecordsPerAccount,
		MaxInviteRecordsTotal:           maxInviteRecordsTotal,
		MaxReportRecordsPerAccount:      maxReportRecordsPerAccount,
		MaxReportRecordsTotal:           maxReportRecordsTotal,
		TrustProxyHeaders:               trustProxyHeaders,
	}, nil
}

func envInt(fallback int, names ...string) (int, error) {
	value := envString(strconv.Itoa(fallback), names...)
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, err
	}
	return parsed, nil
}

func envPositiveInt(fallback int, names ...string) (int, error) {
	parsed, err := envInt(fallback, names...)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", names[0])
	}
	return parsed, nil
}

func envInt64(fallback int64, names ...string) (int64, error) {
	value := envString(strconv.FormatInt(fallback, 10), names...)
	return strconv.ParseInt(value, 10, 64)
}

func envBool(fallback bool, names ...string) (bool, error) {
	value := envString(strconv.FormatBool(fallback), names...)
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("%s must be true or false", names[0])
	}
	return parsed, nil
}

func envString(fallback string, names ...string) string {
	for _, name := range names {
		value := strings.TrimSpace(os.Getenv(name))
		if value != "" {
			return value
		}
	}
	return fallback
}
