package deploy

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/arnozeng98/subflow/internal/state"
)

type savedFile struct {
	path, backup, link string
	existed            bool
	mode               os.FileMode
}
type savedService struct {
	name            string
	active, enabled bool
}
type transaction struct {
	a        *app
	files    []savedFile
	services []savedService
	undos    []func(context.Context) error
	id       string
}

func (a *app) transaction(ctx context.Context, fn func(*transaction) error) error {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	t := &transaction{a: a, id: hex.EncodeToString(b)}
	if err := fn(t); err != nil {
		// Cancellation must not prevent restoring the old executable and service.
		recovery, cancel := context.WithTimeout(context.WithoutCancel(ctx), 90*time.Second)
		defer cancel()
		restore := t.rollback(recovery)
		if restore != nil {
			return errors.Join(err, fmt.Errorf("rollback incomplete; keep .subflow-backup-%s files for recovery: %w", t.id, restore))
		}
		return errors.Join(err, t.cleanup())
	}
	return t.cleanup()
}

func (t *transaction) remember(path string) error {
	if err := safeAncestors(path); err != nil {
		return err
	}
	for _, f := range t.files {
		if f.path == path {
			return nil
		}
	}
	f := savedFile{path: path}
	st, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		t.files = append(t.files, f)
		return nil
	}
	if err != nil {
		return err
	}
	f.existed, f.mode = true, st.Mode()
	if st.Mode()&os.ModeSymlink != 0 {
		f.link, err = os.Readlink(path)
	} else {
		if !st.Mode().IsRegular() {
			return fmt.Errorf("refusing to replace non-regular file %s", path)
		}
		f.backup = path + ".subflow-backup-" + t.id
		data, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		err = state.WriteFile(f.backup, data, st.Mode().Perm())
	}
	if err != nil {
		return err
	}
	t.files = append(t.files, f)
	return nil
}

func (t *transaction) write(path string, data []byte, mode os.FileMode) error {
	if err := t.remember(path); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	// Atomic rename replaces symlinks themselves, never their targets.
	return state.WriteFile(path, data, mode)
}

func (t *transaction) remove(path string) error {
	if err := t.remember(path); err != nil {
		return err
	}
	err := os.Remove(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (t *transaction) symlink(path, target string) error {
	if err := t.remember(path); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	staged := path + ".subflow-link-" + t.id
	if err := os.Symlink(target, staged); err != nil {
		return err
	}
	defer os.Remove(staged)
	return os.Rename(staged, path)
}

func (t *transaction) service(ctx context.Context, name string) error {
	for _, s := range t.services {
		if s.name == name {
			return nil
		}
	}
	s := savedService{name: name}
	for _, query := range []string{"is-active", "is-enabled"} {
		b, err := t.a.o.Execute(ctx, Command{Name: "systemctl", Args: []string{query, name}})
		value := strings.TrimSpace(string(b))
		switch query {
		case "is-active":
			s.active = value == "active" || value == "activating" || value == "reloading"
			if err != nil && value != "inactive" && value != "failed" && value != "unknown" {
				return fmt.Errorf("inspect %s: %w", name, err)
			}
		case "is-enabled":
			s.enabled = value == "enabled" || value == "enabled-runtime"
			if err != nil && value != "disabled" && value != "not-found" && value != "static" && value != "masked" {
				return fmt.Errorf("inspect %s: %w", name, err)
			}
		}
	}
	t.services = append(t.services, s)
	return nil
}

func (t *transaction) activate(ctx context.Context, names ...string) error {
	if err := t.a.cmd(ctx, "systemctl", "daemon-reload"); err != nil {
		return err
	}
	for _, name := range names {
		if err := t.a.cmd(ctx, "systemctl", "enable", name); err != nil {
			return err
		}
		var err error
		if name == "sing-box.service" {
			err = t.a.kernelControl(ctx, "start")
		} else {
			err = t.a.cmd(ctx, "systemctl", "restart", name)
		}
		if err != nil {
			return err
		}
		if err := t.a.cmd(ctx, "systemctl", "is-active", "--quiet", name); err != nil {
			return fmt.Errorf("%s did not become active: %w", name, err)
		}
	}
	return nil
}

func (t *transaction) rollback(ctx context.Context) error {
	var errs []error
	// Stop candidate processes before restoring/deleting their binaries or remote
	// tunnels. Disable new units before removing their unit files.
	for _, s := range t.services {
		if !fileExists(t.a.path(unitDir + s.name)) {
			continue
		}
		if s.name == "sing-box.service" {
			if err := t.a.kernelControl(ctx, "prepare-restart"); err != nil {
				return errors.Join(append(errs, err)...)
			}
		} else {
			errs = append(errs, t.a.cmd(ctx, "systemctl", "stop", s.name))
		}
		if !s.enabled {
			errs = append(errs, t.a.cmd(ctx, "systemctl", "disable", s.name))
		}
	}
	for i := len(t.undos) - 1; i >= 0; i-- {
		errs = append(errs, t.undos[i](ctx))
	}
	for i := len(t.files) - 1; i >= 0; i-- {
		f := t.files[i]
		if !f.existed {
			err := os.Remove(f.path)
			if !errors.Is(err, os.ErrNotExist) {
				errs = append(errs, err)
			}
			continue
		}
		if f.link != "" {
			if err := os.Remove(f.path); err != nil && !errors.Is(err, os.ErrNotExist) {
				errs = append(errs, err)
				continue
			}
			errs = append(errs, os.Symlink(f.link, f.path))
		} else {
			data, err := os.ReadFile(f.backup)
			if err == nil {
				err = state.WriteFile(f.path, data, f.mode.Perm())
			}
			errs = append(errs, err)
		}
	}
	if len(t.services) > 0 {
		errs = append(errs, t.a.cmd(ctx, "systemctl", "daemon-reload"))
		for _, s := range t.services {
			op := "disable"
			if s.enabled {
				op = "enable"
			}
			// A newly installed unit has already been removed; disabling it now is unnecessary.
			if s.enabled || fileExists(t.a.path(unitDir+s.name)) {
				errs = append(errs, t.a.cmd(ctx, "systemctl", op, s.name))
			}
			op = "stop"
			if s.active {
				op = "restart"
			}
			if s.active || fileExists(t.a.path(unitDir+s.name)) {
				if s.name == "sing-box.service" {
					if s.active {
						op = "start"
					}
					errs = append(errs, t.a.kernelControl(ctx, op))
				} else {
					errs = append(errs, t.a.cmd(ctx, "systemctl", op, s.name))
				}
			}
		}
	}
	return errors.Join(errs...)
}

func (t *transaction) cleanup() error {
	var errs []error
	for _, f := range t.files {
		if f.backup != "" {
			if err := os.Remove(f.backup); err != nil && !errors.Is(err, os.ErrNotExist) {
				errs = append(errs, err)
			}
		}
	}
	return errors.Join(errs...)
}

func fileExists(path string) bool { _, err := os.Stat(path); return err == nil }

func safeAncestors(path string) error {
	dir := filepath.Dir(path)
	for {
		st, err := os.Lstat(dir)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if err == nil && st.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing to write through symlink directory %s", dir)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return nil
		}
		dir = parent
	}
}
