package storage

import (
	"context"
	"io"
	"strings"
	"testing"
)

func TestLocalStoreWriteReadDelete(t *testing.T) {
	ctx := context.Background()
	store, err := NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocal() error = %v", err)
	}

	if err := store.Write(ctx, "message-1.blob", strings.NewReader("ciphertext")); err != nil {
		t.Fatalf("Write() error = %v", err)
	}

	readCloser, err := store.Read(ctx, "message-1.blob")
	if err != nil {
		t.Fatalf("Read() error = %v", err)
	}
	defer readCloser.Close()

	body, err := io.ReadAll(readCloser)
	if err != nil {
		t.Fatalf("ReadAll() error = %v", err)
	}
	if string(body) != "ciphertext" {
		t.Fatalf("blob body = %q, want %q", string(body), "ciphertext")
	}

	if err := store.Delete(ctx, "message-1.blob"); err != nil {
		t.Fatalf("Delete() error = %v", err)
	}
	if _, err := store.Read(ctx, "message-1.blob"); err == nil {
		t.Fatalf("Read() after Delete() error = nil, want error")
	}
}

func TestLocalStoreNestedPathCreatesDirectories(t *testing.T) {
	ctx := context.Background()
	store, err := NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocal() error = %v", err)
	}

	if err := store.Write(ctx, "messages/2026/message-2.blob", strings.NewReader("nested")); err != nil {
		t.Fatalf("Write() error = %v", err)
	}

	readCloser, err := store.Read(ctx, "messages/2026/message-2.blob")
	if err != nil {
		t.Fatalf("Read() error = %v", err)
	}
	readCloser.Close()
}

func TestLocalStoreRejectsUnsafePaths(t *testing.T) {
	store, err := NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("NewLocal() error = %v", err)
	}

	for _, key := range []string{"../outside", "/absolute", "C:/absolute", "nested/../../outside"} {
		if _, err := store.Path(key); err == nil {
			t.Fatalf("Path(%q) error = nil, want error", key)
		}
	}
}
