package nodehost

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/arnozeng98/subflow/internal/state"
)

type savedFile struct {
	Path   string `json:"path"`
	Data   []byte `json:"data"`
	Exists bool   `json:"exists"`
}
type journal struct {
	Files     []savedFile `json:"files"`
	Committed bool        `json:"committed"`
	NextDB    *database   `json:"next_db,omitempty"`
}

func quarantine(db *database, next *database) {
	seen := map[UncertainPeriod]bool{}
	for _, p := range db.Uncertain {
		seen[p] = true
	}
	for _, source := range []*database{db, next} {
		if source == nil {
			continue
		}
		for name, u := range source.Users {
			if name == "admin" {
				continue
			}
			p := UncertainPeriod{name, u.Period}
			if !seen[p] {
				db.Uncertain = append(db.Uncertain, p)
				seen[p] = true
			}
		}
	}
}

func (h *host) journalPath() string { return h.opts.Config.UserDBPath + ".journal" }
func (h *host) snapshot() (journal, error) {
	var j journal
	c := h.opts.Config
	for _, p := range []string{c.ConfigPath, c.UserDBPath, c.MetaPath, c.MetaPath + ".routing", c.UserDBPath + ".central"} {
		b, e := os.ReadFile(p)
		if e != nil && !errors.Is(e, os.ErrNotExist) {
			return j, e
		}
		j.Files = append(j.Files, savedFile{p, b, e == nil})
	}
	return j, nil
}

func (h *host) restore(j journal) error {
	c := h.opts.Config
	allowed := map[string]bool{c.ConfigPath: true, c.UserDBPath: true, c.MetaPath: true, c.MetaPath + ".routing": true, c.UserDBPath + ".central": true}
	for _, f := range j.Files {
		if !allowed[f.Path] {
			return errors.New("journal contains invalid path")
		}
		if f.Exists {
			if err := state.WriteFile(f.Path, f.Data, 0600); err != nil {
				return err
			}
		} else if err := os.Remove(f.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

func (h *host) recover(ctx context.Context) error {
	var j journal
	err := state.ReadJSON(h.journalPath(), &j)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !j.Committed {
		fmt.Fprintln(h.errOut, "ERROR: interrupted node transaction; stopping runtime and quarantining uncertain ordinary periods")
		if err := h.command(ctx, "stop"); err != nil {
			return err
		}
		if err := h.restore(j); err != nil {
			return err
		}
		var db database
		if err := optionalJSON(h.opts.Config.UserDBPath, &db); err != nil {
			return err
		}
		if db.Users != nil {
			db.Counters = map[string]int64{}
			db.RuntimeStopped = true
			// The process may have run after an interrupted restart. Never
			// reopen ordinary traffic until explicit accounting recovery.
			db.StatsBlocked = true
			quarantine(&db, j.NextDB)
			if err := state.WriteJSON(h.opts.Config.UserDBPath, db); err != nil {
				return err
			}
		}
	}
	return state.WriteJSON(h.journalPath(), journal{Committed: true})
}

// mutate accounts the live runtime before taking the rollback snapshot.
func (h *host) mutate(ctx context.Context, change func() error) error {
	held := h.db.RestartPrepared && !h.allowPrepared
	if held && !h.editWhilePrepared {
		return ErrRestartPrepared
	}
	if err := h.sample(ctx); err != nil {
		return err
	}
	beforeDB := clone(h.db)
	j, err := h.snapshot()
	if err != nil {
		return err
	}
	if err := h.applyScheduledResets(); err != nil {
		return err
	}
	if err := change(); err != nil {
		return err
	}
	if err := h.render(); err != nil {
		return err
	}
	c := h.opts.Config
	candidate := c.ConfigPath + ".candidate"
	if err := state.WriteJSON(candidate, h.config); err != nil {
		return err
	}
	defer os.Remove(candidate)
	if _, err := h.execute(ctx, "sing-box", "check", "-c", candidate); err != nil {
		return errors.New("sing-box configuration check failed")
	}
	changedDB := h.db
	h.db = clone(beforeDB)
	if err := h.sample(ctx); err != nil {
		return err
	}
	finalDB := h.db
	j, err = h.snapshot()
	if err != nil {
		return err
	}
	h.db = changedDB
	h.db.StatsBlocked = finalDB.StatsBlocked
	for _, p := range finalDB.Uncertain {
		found := false
		for _, q := range h.db.Uncertain {
			if p == q {
				found = true
				break
			}
		}
		if !found {
			h.db.Uncertain = append(h.db.Uncertain, p)
		}
	}
	for name, old := range beforeDB.Users {
		if name == "admin" {
			continue
		}
		final := finalDB.Users[name]
		next := h.db.Users[name]
		if final == nil || next == nil {
			continue
		}
		up, down := final.Up-old.Up, final.Down-old.Down
		if up < 0 || down < 0 {
			return errors.New("accounting counters regressed")
		}
		if next.Period == old.Period && next.Granted == old.Granted {
			next.Up = sum(next.Up, up)
			next.Down = sum(next.Down, down)
		} else if old.Granted {
			h.archive(Report{name, old.Period, up, down})
		}
	}
	nextDB := clone(h.db)
	j.NextDB = &nextDB
	if err := state.WriteJSON(h.journalPath(), j); err != nil {
		return err
	}
	rollback := func(cause error) error {
		stopErr := h.command(ctx, "stop")
		restoreErr := h.restore(j)
		if restoreErr == nil {
			restoreErr = h.load()
			if restoreErr == nil {
				h.db.Counters = map[string]int64{}
				h.db.RuntimeID = ""
				h.db.RuntimeStopped = true
				h.db.StatsBlocked = true
				quarantine(&h.db, j.NextDB)
				restoreErr = state.WriteJSON(c.UserDBPath, h.db)
			}
		}
		if restoreErr == nil {
			restoreErr = state.WriteJSON(h.journalPath(), journal{Committed: true})
		}
		return errors.Join(cause, stopErr, restoreErr)
	}
	// The final durable sample includes traffic during candidate validation.
	// sing-box has no atomic drain-and-snapshot RPC; the stop window remains
	// bounded by systemd shutdown time, not a byte-perfect quota guarantee.
	if err := h.command(ctx, "stop"); err != nil {
		return rollback(err)
	}
	if err := h.render(); err != nil {
		return rollback(err)
	}
	if err := state.WriteJSON(candidate, h.config); err != nil {
		return rollback(err)
	}
	if _, err := h.execute(ctx, "sing-box", "check", "-c", candidate); err != nil {
		return rollback(errors.New("final configuration check failed"))
	}
	h.db.Counters = map[string]int64{}
	h.db.RuntimeID = ""
	h.db.RuntimeStopped = held
	for _, f := range []struct {
		p string
		v any
	}{{c.ConfigPath, h.config}, {c.UserDBPath, h.db}, {c.MetaPath, h.meta}, {c.MetaPath + ".routing", h.routing}, {c.UserDBPath + ".central", h.central}} {
		if err := state.WriteJSON(f.p, f.v); err != nil {
			return rollback(err)
		}
	}
	if !held {
		if err := h.command(ctx, "restart"); err != nil {
			return rollback(err)
		}
	}
	if err := state.WriteJSON(h.journalPath(), journal{Committed: true}); err != nil {
		return rollback(err)
	}
	return nil
}

func clone[T any](v T) T {
	b, _ := json.Marshal(v)
	var result T
	_ = json.Unmarshal(b, &result)
	return result
}
