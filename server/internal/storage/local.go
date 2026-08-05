package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

type Store interface {
	Write(ctx context.Context, key string, data io.Reader) error
	Read(ctx context.Context, key string) (io.ReadCloser, error)
	Delete(ctx context.Context, key string) error
	Path(key string) (string, error)
	Ready(ctx context.Context) error
}

type LocalStore struct {
	root string
}

func NewLocal(root string) (*LocalStore, error) {
	if strings.TrimSpace(root) == "" {
		return nil, fmt.Errorf("blob storage path is required")
	}

	absoluteRoot, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("resolve blob storage path: %w", err)
	}
	absoluteRoot = filepath.Clean(absoluteRoot)

	if err := os.MkdirAll(absoluteRoot, 0o700); err != nil {
		return nil, fmt.Errorf("create blob storage directory %q: %w", absoluteRoot, err)
	}

	return &LocalStore{root: absoluteRoot}, nil
}

func (s *LocalStore) Write(ctx context.Context, key string, data io.Reader) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if data == nil {
		return fmt.Errorf("blob data reader is required")
	}

	fullPath, err := s.Path(key)
	if err != nil {
		return err
	}
	if _, err := os.Stat(fullPath); err == nil {
		return fmt.Errorf("blob %q already exists", key)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(fullPath), 0o700); err != nil {
		return fmt.Errorf("create blob directory: %w", err)
	}

	tempFile, err := os.CreateTemp(filepath.Dir(fullPath), "."+filepath.Base(fullPath)+".*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary blob: %w", err)
	}

	tempPath := tempFile.Name()
	committed := false
	defer func() {
		if !committed {
			_ = os.Remove(tempPath)
		}
	}()

	if _, err := io.Copy(tempFile, data); err != nil {
		_ = tempFile.Close()
		return fmt.Errorf("write blob: %w", err)
	}
	if err := tempFile.Close(); err != nil {
		return fmt.Errorf("close blob: %w", err)
	}
	if err := os.Rename(tempPath, fullPath); err != nil {
		return fmt.Errorf("commit blob: %w", err)
	}

	committed = true
	return nil
}

func (s *LocalStore) Read(ctx context.Context, key string) (io.ReadCloser, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	fullPath, err := s.Path(key)
	if err != nil {
		return nil, err
	}

	file, err := os.Open(fullPath)
	if err != nil {
		return nil, fmt.Errorf("open blob: %w", err)
	}
	return file, nil
}

func (s *LocalStore) Delete(ctx context.Context, key string) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	fullPath, err := s.Path(key)
	if err != nil {
		return err
	}

	if err := os.Remove(fullPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("delete blob: %w", err)
	}
	return nil
}

func (s *LocalStore) Path(key string) (string, error) {
	cleanKey, err := cleanBlobKey(key)
	if err != nil {
		return "", err
	}

	fullPath := filepath.Join(s.root, filepath.FromSlash(cleanKey))
	relative, err := filepath.Rel(s.root, fullPath)
	if err != nil {
		return "", fmt.Errorf("resolve blob path: %w", err)
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("blob key escapes storage root")
	}

	return fullPath, nil
}

func (s *LocalStore) Ready(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	info, err := os.Stat(s.root)
	if err != nil {
		return fmt.Errorf("stat blob storage: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("blob storage path is not a directory")
	}
	return nil
}

func cleanBlobKey(key string) (string, error) {
	key = strings.TrimSpace(key)
	if key == "" {
		return "", fmt.Errorf("blob key is required")
	}
	if strings.Contains(key, ":") || filepath.IsAbs(key) || path.IsAbs(key) {
		return "", fmt.Errorf("blob key must be relative")
	}

	key = strings.ReplaceAll(key, "\\", "/")
	cleaned := path.Clean(key)
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", fmt.Errorf("blob key must stay within storage root")
	}

	for _, part := range strings.Split(cleaned, "/") {
		if part == "" || part == "." || part == ".." {
			return "", fmt.Errorf("blob key contains unsafe path segment")
		}
	}

	return cleaned, nil
}
