package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/joaquimpacer/speakeasy/server/internal/api"
	"github.com/joaquimpacer/speakeasy/server/internal/config"
	"github.com/joaquimpacer/speakeasy/server/internal/db"
	"github.com/joaquimpacer/speakeasy/server/internal/storage"
)

func main() {
	logger := log.New(os.Stdout, "speakeasy: ", log.LstdFlags|log.LUTC)

	cfg, err := config.Load()
	if err != nil {
		logger.Fatalf("load config: %v", err)
	}

	ctx := context.Background()

	database, err := db.Open(ctx, cfg.DBPath)
	if err != nil {
		logger.Fatalf("open database: %v", err)
	}
	defer database.Close()

	blobStore, err := storage.NewLocal(cfg.BlobStoragePath)
	if err != nil {
		logger.Fatalf("open blob storage: %v", err)
	}

	relay := api.NewWithOptions(database, blobStore, api.Options{
		RetentionDays:                   cfg.UndeliveredRetentionDays,
		ChallengeTTL:                    cfg.ChallengeTTL,
		SessionTTL:                      cfg.SessionTTL,
		MaxUploadBytes:                  cfg.MaxUploadBytes,
		MaxPendingBytesPerAccount:       cfg.MaxPendingBytesPerAccount,
		MaxPendingMessagesPerAccount:    cfg.MaxPendingMessagesPerAccount,
		MaxPendingBytesTotal:            cfg.MaxPendingBytesTotal,
		RegistrationRatePerIP:           cfg.RegistrationRatePerIP,
		RegistrationRateGlobal:          cfg.RegistrationRateGlobal,
		RegistrationRateWindow:          time.Hour,
		AuthRatePerIP:                   cfg.AuthRatePerIP,
		AuthRateGlobal:                  cfg.AuthRateGlobal,
		AuthRateWindow:                  15 * time.Minute,
		UploadRatePerAccount:            cfg.UploadRatePerAccount,
		UploadRateWindow:                time.Hour,
		InviteRatePerAccount:            cfg.InviteRatePerAccount,
		InviteRateWindow:                time.Hour,
		ReportRatePerAccount:            cfg.ReportRatePerAccount,
		ReportRateWindow:                time.Hour,
		MaxOutstandingInvitesPerAccount: cfg.MaxOutstandingInvitesPerAccount,
		MaxInviteRecordsPerAccount:      cfg.MaxInviteRecordsPerAccount,
		MaxInviteRecordsTotal:           cfg.MaxInviteRecordsTotal,
		MaxReportRecordsPerAccount:      cfg.MaxReportRecordsPerAccount,
		MaxReportRecordsTotal:           cfg.MaxReportRecordsTotal,
		TrustProxyHeaders:               cfg.TrustProxyHeaders,
	})
	handler := relay.Handler()
	httpServer := &http.Server{
		Addr:              cfg.Address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Minute,
		IdleTimeout:       60 * time.Second,
	}

	runCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		err := relay.RunCleanupLoop(runCtx, time.Hour, func(result api.CleanupResult, cleanupErr error) {
			if cleanupErr != nil {
				logger.Printf("retention cleanup failed result=%+v error=%v", result, cleanupErr)
				return
			}
			if result.DeletedMessages != 0 || result.DeletedPendingBlobs != 0 ||
				result.DeletedSessions != 0 || result.DeletedChallenges != 0 {
				logger.Printf("retention cleanup completed result=%+v", result)
			}
		})
		if err != nil {
			logger.Printf("retention cleanup stopped: %v", err)
		}
	}()

	errCh := make(chan error, 1)
	go func() {
		logger.Printf(
			"listening addr=%s db_path=%s blob_storage_path=%s undelivered_retention_days=%d max_upload_bytes=%d max_pending_bytes_per_account=%d max_pending_messages_per_account=%d max_pending_bytes_total=%d trust_proxy_headers=%t",
			cfg.Address,
			cfg.DBPath,
			cfg.BlobStoragePath,
			cfg.UndeliveredRetentionDays,
			cfg.MaxUploadBytes,
			cfg.MaxPendingBytesPerAccount,
			cfg.MaxPendingMessagesPerAccount,
			cfg.MaxPendingBytesTotal,
			cfg.TrustProxyHeaders,
		)
		errCh <- httpServer.ListenAndServe()
	}()

	select {
	case <-runCtx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			logger.Fatalf("shutdown server: %v", err)
		}
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Fatalf("serve http: %v", err)
		}
	}
}
