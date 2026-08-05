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

	handler := api.New(database, blobStore, cfg.UndeliveredRetentionDays).Handler()
	httpServer := &http.Server{
		Addr:              cfg.Address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	runCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		logger.Printf(
			"listening addr=%s db_path=%s blob_storage_path=%s undelivered_retention_days=%d",
			cfg.Address,
			cfg.DBPath,
			cfg.BlobStoragePath,
			cfg.UndeliveredRetentionDays,
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
