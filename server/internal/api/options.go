package api

import "time"

const (
	defaultChallengeTTL                 = 5 * time.Minute
	defaultSessionTTL                   = 30 * 24 * time.Hour
	defaultMaxUploadBytes               = int64(64 << 20)
	defaultMaxPendingBytesPerAccount    = int64(256 << 20)
	defaultMaxPendingMessagesPerAccount = 25
	defaultMaxPendingBytesTotal         = int64(2 << 30)
	defaultRegistrationRatePerIP        = 5
	defaultRegistrationRateGlobal       = 100
	defaultRegistrationRateWindow       = time.Hour
	defaultAuthRatePerIP                = 30
	defaultAuthRateGlobal               = 1000
	defaultAuthRateWindow               = 15 * time.Minute
	defaultUploadRatePerAccount         = 60
	defaultUploadRateWindow             = time.Hour
	defaultInviteRatePerAccount         = 10
	defaultInviteRateWindow             = time.Hour
	defaultReportRatePerAccount         = 20
	defaultReportRateWindow             = time.Hour
	defaultMaxOutstandingInvites        = 5
	defaultMaxInviteRecordsPerAccount   = 1_000
	defaultMaxInviteRecordsTotal        = 100_000
	defaultMaxReportRecordsPerAccount   = 1_000
	defaultMaxReportRecordsTotal        = 100_000
)

// Options contains relay limits that are safe to tune per deployment. Zero
// values use conservative defaults so callers cannot accidentally disable a
// public-release guard.
type Options struct {
	RetentionDays int

	ChallengeTTL time.Duration
	SessionTTL   time.Duration

	MaxUploadBytes               int64
	MaxPendingBytesPerAccount    int64
	MaxPendingMessagesPerAccount int
	MaxPendingBytesTotal         int64

	RegistrationRatePerIP  int
	RegistrationRateGlobal int
	RegistrationRateWindow time.Duration
	AuthRatePerIP          int
	AuthRateGlobal         int
	AuthRateWindow         time.Duration
	UploadRatePerAccount   int
	UploadRateWindow       time.Duration
	InviteRatePerAccount   int
	InviteRateWindow       time.Duration
	ReportRatePerAccount   int
	ReportRateWindow       time.Duration

	MaxOutstandingInvitesPerAccount int
	MaxInviteRecordsPerAccount      int
	MaxInviteRecordsTotal           int
	MaxReportRecordsPerAccount      int
	MaxReportRecordsTotal           int

	// TrustProxyHeaders permits X-Forwarded-For/X-Real-IP only when the relay is
	// reachable exclusively through a trusted reverse proxy. It must remain
	// false when clients can connect to the relay directly.
	TrustProxyHeaders bool
}

func normalizeOptions(options Options) Options {
	if options.RetentionDays <= 0 {
		options.RetentionDays = 7
	}
	if options.ChallengeTTL <= 0 {
		options.ChallengeTTL = defaultChallengeTTL
	}
	if options.SessionTTL <= 0 {
		options.SessionTTL = defaultSessionTTL
	}
	if options.MaxUploadBytes <= 0 {
		options.MaxUploadBytes = defaultMaxUploadBytes
	}
	if options.MaxPendingBytesPerAccount <= 0 {
		options.MaxPendingBytesPerAccount = defaultMaxPendingBytesPerAccount
	}
	if options.MaxPendingMessagesPerAccount <= 0 {
		options.MaxPendingMessagesPerAccount = defaultMaxPendingMessagesPerAccount
	}
	if options.MaxPendingBytesTotal <= 0 {
		options.MaxPendingBytesTotal = defaultMaxPendingBytesTotal
	}
	if options.RegistrationRatePerIP <= 0 {
		options.RegistrationRatePerIP = defaultRegistrationRatePerIP
	}
	if options.RegistrationRateGlobal <= 0 {
		options.RegistrationRateGlobal = defaultRegistrationRateGlobal
	}
	if options.RegistrationRateWindow <= 0 {
		options.RegistrationRateWindow = defaultRegistrationRateWindow
	}
	if options.AuthRatePerIP <= 0 {
		options.AuthRatePerIP = defaultAuthRatePerIP
	}
	if options.AuthRateGlobal <= 0 {
		options.AuthRateGlobal = defaultAuthRateGlobal
	}
	if options.AuthRateWindow <= 0 {
		options.AuthRateWindow = defaultAuthRateWindow
	}
	if options.UploadRatePerAccount <= 0 {
		options.UploadRatePerAccount = defaultUploadRatePerAccount
	}
	if options.UploadRateWindow <= 0 {
		options.UploadRateWindow = defaultUploadRateWindow
	}
	if options.InviteRatePerAccount <= 0 {
		options.InviteRatePerAccount = defaultInviteRatePerAccount
	}
	if options.InviteRateWindow <= 0 {
		options.InviteRateWindow = defaultInviteRateWindow
	}
	if options.ReportRatePerAccount <= 0 {
		options.ReportRatePerAccount = defaultReportRatePerAccount
	}
	if options.ReportRateWindow <= 0 {
		options.ReportRateWindow = defaultReportRateWindow
	}
	if options.MaxOutstandingInvitesPerAccount <= 0 {
		options.MaxOutstandingInvitesPerAccount = defaultMaxOutstandingInvites
	}
	if options.MaxInviteRecordsPerAccount <= 0 {
		options.MaxInviteRecordsPerAccount = defaultMaxInviteRecordsPerAccount
	}
	if options.MaxInviteRecordsTotal <= 0 {
		options.MaxInviteRecordsTotal = defaultMaxInviteRecordsTotal
	}
	if options.MaxReportRecordsPerAccount <= 0 {
		options.MaxReportRecordsPerAccount = defaultMaxReportRecordsPerAccount
	}
	if options.MaxReportRecordsTotal <= 0 {
		options.MaxReportRecordsTotal = defaultMaxReportRecordsTotal
	}
	return options
}
