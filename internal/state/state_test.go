package state

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestJSONRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	if err := WriteJSON(path, map[string]any{"count": json.Number("9007199254740993")}); err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := ReadJSON(path, &got); err != nil {
		t.Fatal(err)
	}
	if got["count"] != json.Number("9007199254740993") {
		t.Fatalf("precision lost: %v", got)
	}
	if err := os.WriteFile(path, []byte("{} {}"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := ReadJSON(path, &got); err == nil {
		t.Fatal("accepted trailing JSON")
	}
}

func TestConcurrentReadModifyWrite(t *testing.T) {
	dir := t.TempDir()
	path, lock := filepath.Join(dir, "count.json"), filepath.Join(dir, "state.lock")
	if err := WriteJSON(path, 0); err != nil {
		t.Fatal(err)
	}
	var group sync.WaitGroup
	for range 12 {
		group.Go(func() {
			err := WithLock(t.Context(), lock, func() error {
				var n int
				if err := ReadJSON(path, &n); err != nil {
					return err
				}
				return WriteJSON(path, n+1)
			})
			if err != nil {
				t.Error(err)
			}
		})
	}
	group.Wait()
	var n int
	if err := ReadJSON(path, &n); err != nil || n != 12 {
		t.Fatalf("lost update: %d, %v", n, err)
	}
}

func TestLockCancellation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lock")
	if err := WithLock(t.Context(), path, func() error {
		ctx, cancel := context.WithTimeout(t.Context(), 50*time.Millisecond)
		defer cancel()
		if err := WithLock(ctx, path, func() error {
			t.Error("entered locked section")
			return nil
		}); err == nil {
			t.Error("lock wait did not time out")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}
