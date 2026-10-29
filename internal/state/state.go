package state

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/gofrs/flock"
)

func ReadJSON(path string, dest any) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open state %s: %w", path, err)
	}
	defer f.Close()
	decoder := json.NewDecoder(f)
	decoder.UseNumber()
	if err := decoder.Decode(dest); err != nil {
		return fmt.Errorf("decode state %s: %w", path, err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			err = errors.New("multiple JSON values")
		}
		return fmt.Errorf("decode state %s: %w", path, err)
	}
	return nil
}

func WriteJSON(path string, value any) error {
	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return fmt.Errorf("encode state %s: %w", path, err)
	}
	return WriteFile(path, buf.Bytes(), 0600)
}

// WriteFile replaces a file only after the complete new contents are flushed.
// Callers must hold the shared lock across the entire read-modify-write operation.
func WriteFile(path string, data []byte, mode os.FileMode) (err error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("create state directory: %w", err)
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return fmt.Errorf("create state temporary file: %w", err)
	}
	tmp := f.Name()
	defer func() {
		if cleanup := os.Remove(tmp); cleanup != nil && !errors.Is(cleanup, os.ErrNotExist) {
			err = errors.Join(err, fmt.Errorf("remove temporary state: %w", cleanup))
		}
	}()
	if err := f.Chmod(mode); err != nil {
		return errors.Join(err, f.Close())
	}
	if _, err := f.Write(data); err != nil {
		return errors.Join(err, f.Close())
	}
	if err := f.Sync(); err != nil {
		return errors.Join(err, f.Close())
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("replace state %s: %w", path, err)
	}
	return syncDirectory(dir)
}

func WithLock(ctx context.Context, path string, fn func() error) (err error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create lock directory: %w", err)
	}
	lock := flock.New(path, flock.SetPermissions(0600))
	locked, err := lock.TryLockContext(ctx, 20*time.Millisecond)
	if err != nil {
		return fmt.Errorf("lock state %s: %w", path, err)
	}
	if !locked {
		return fmt.Errorf("lock state %s: %w", path, context.Canceled)
	}
	defer func() { err = errors.Join(err, lock.Unlock()) }()
	return fn()
}
