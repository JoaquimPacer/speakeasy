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
	if err := os.MkdirAll(filepath.Dir(fullPath), 0o700); err != nil {
		return fmt.Errorf("create blob directory: %w", err)
	}

	// The API durably registers this final key before Write begins. Writing to
	// that key directly ensures a process crash leaves a discoverable partial
	// file instead of an unregistered temporary filename. No reader receives the
	// key until the complete write and message transaction both succeed.
	blobFile, err := os.OpenFile(fullPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return fmt.Errorf("blob %q already exists", key)
		}
		return fmt.Errorf("create blob: %w", err)
	}

	committed := false
	defer func() {
		if !committed {
			_ = blobFile.Close()
			_ = os.Remove(fullPath)
		}
	}()

	if _, err := io.Copy(blobFile, data); err != nil {
		return fmt.Errorf("write blob: %w", err)
	}
	if err := blobFile.Sync(); err != nil {
		return fmt.Errorf("sync blob: %w", err)
	}
	if err := blobFile.Close(); err != nil {
		return fmt.Errorf("close blob: %w", err)
	}
	if err := syncDirectoryTree(filepath.Dir(fullPath), s.root); err != nil {
		return fmt.Errorf("sync blob directory: %w", err)
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
	if err := syncDirectoryTree(filepath.Dir(fullPath), s.root); err != nil {
		return fmt.Errorf("sync blob deletion: %w", err)
	}
	return nil
}

func syncDirectory(directoryPath string) error {
	directory, err := os.Open(directoryPath)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func syncDirectoryTree(directoryPath string, root string) error {
	current := filepath.Clean(directoryPath)
	root = filepath.Clean(root)
	relative, err := filepath.Rel(root, current)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return fmt.Errorf("blob directory %q is outside storage root %q", directoryPath, root)
	}
	for {
		if err := syncDirectory(current); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if current == root {
			return nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return fmt.Errorf("blob directory %q is outside storage root %q", directoryPath, root)
		}
		current = parent
	}
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
