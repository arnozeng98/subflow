package nodehost

import (
	"context"
	"errors"

	"github.com/arnozeng98/subflow/internal/state"
)

var ErrRestartPrepared = errors.New("restart is prepared; resume with system start or system restart")

// prepareRestart stops consumption before an external binary/kernel operation.
// The durable hold prevents the agent from starting the old or half-updated core.
func (h *host) prepareRestart(ctx context.Context) error {
	h.db.RestartPrepared = true
	if err := state.WriteJSON(h.opts.Config.UserDBPath, h.db); err != nil {
		return errors.Join(err, h.command(ctx, "stop"))
	}
	if err := h.sample(ctx); err != nil {
		return err
	}
	if err := h.command(ctx, "stop"); err != nil {
		return err
	}
	h.db.RuntimeStopped = true
	h.db.RuntimeID = ""
	h.db.Counters = map[string]int64{}
	h.db.ProbeRequired = true
	return state.WriteJSON(h.opts.Config.UserDBPath, h.db)
}

func (h *host) bootstrap(ctx context.Context) error {
	return h.locked(ctx, func() error {
		if h.db.RestartPrepared {
			return h.prepareRestart(ctx)
		}
		// Account the old generation, then boot an ordinary-user-free runtime.
		// Only a subsequent successful RPC probe may clear ProbeRequired.
		if err := h.mutate(ctx, func() error { h.db.ProbeRequired = true; return nil }); err != nil {
			return h.stopUncertain(ctx, err)
		}
		return nil
	})
}
