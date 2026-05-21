package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

const (
	defaultAddress                 = ":8080"
	defaultDBPath                  = "data/speakeasy.db"
	defaultBlobStoragePath         = "data/blobs"
	defaultUndeliveredRetentionDays = 7
)

type Config struct {
	Address                  string
	DBPath                   string
	BlobStoragePath          string
	UndeliveredRetentionDays int
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
		UndeliveredRetentionDays: retentionDays,
	}, nil
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
