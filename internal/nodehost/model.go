// Package nodehost implements the native, independently authored node runtime.
package nodehost

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/arnozeng98/subflow/internal/settings"
	"github.com/arnozeng98/subflow/internal/state"
)

type Object = map[string]any

type Options struct {
	Config     settings.Config
	Command    func(context.Context, string, ...string) ([]byte, error)
	Stats      func(context.Context, string) ([]Stat, error)
	Now        func() time.Time
	HTTPClient *http.Client
}

type Stat struct {
	Name  string `json:"name"`
	Value int64  `json:"value"`
}

type User struct {
	Enabled           bool                `json:"enabled"`
	DisabledReason    *string             `json:"disabled_reason"`
	QuotaGB           float64             `json:"quota_gb"`
	QuotaBytes        int64               `json:"quota_bytes"`
	Up                int64               `json:"used_up_bytes"`
	Down              int64               `json:"used_down_bytes"`
	Manual            int64               `json:"manual_added_bytes"`
	LastReset         string              `json:"last_reset_period"`
	ResetDay          int                 `json:"reset_day"`
	ResetAnchor       int64               `json:"reset_anchor"`
	ExpireAt          string              `json:"expire_at"`
	Expires           int64               `json:"expires_at"`
	Nodes             []string            `json:"nodes"`
	Period            int64               `json:"period"`
	Grant             int64               `json:"grant_bytes"`
	Granted           bool                `json:"centrally_granted"`
	Credentials       map[string]Object   `json:"credentials"`
	CredentialAliases map[string][]Object `json:"credential_aliases,omitempty"`
	hasNativeExpiry   bool
}

type database struct {
	Users           map[string]*User  `json:"users"`
	Counters        map[string]int64  `json:"runtime_counters"`
	StatsBlocked    bool              `json:"stats_blocked"`
	RuntimeStopped  bool              `json:"runtime_stopped"`
	RuntimeID       string            `json:"runtime_id,omitempty"`
	RestartPrepared bool              `json:"restart_prepared,omitempty"`
	ProbeRequired   bool              `json:"probe_required,omitempty"`
	Archive         []Report          `json:"archived_reports,omitempty"`
	Uncertain       []UncertainPeriod `json:"uncertain_periods,omitempty"`
}

type UncertainPeriod struct {
	Username string `json:"username"`
	Period   int64  `json:"period"`
}

type nodeMeta struct {
	PublicKey string `json:"public_key,omitempty"`
	Protocol  string `json:"protocol,omitempty"`
	TLSMode   string `json:"tls_mode,omitempty"`
}

type routing struct {
	Relay Object      `json:"relay,omitempty"`
	WARP  Object      `json:"warp,omitempty"`
	Full  string      `json:"full,omitempty"`
	Rules []RouteRule `json:"rules,omitempty"`
}

type RouteRule struct {
	Tag      string `json:"tag"`
	Path     string `json:"path"`
	Outbound string `json:"outbound"`
}

type host struct {
	opts              Options
	out, errOut       io.Writer
	config            Object
	db                database
	meta              map[string]nodeMeta
	routing           routing
	central           centralState
	allowPrepared     bool
	editWhilePrepared bool
}

func newHost(opts Options, out, errOut io.Writer) *host {
	if opts.Command == nil {
		opts.Command = func(ctx context.Context, name string, args ...string) ([]byte, error) {
			return exec.CommandContext(ctx, name, args...).CombinedOutput()
		}
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if opts.Stats == nil {
		opts.Stats = QueryStats
	}
	if out == nil {
		out = io.Discard
	}
	if errOut == nil {
		errOut = io.Discard
	}
	return &host{opts: opts, out: out, errOut: errOut}
}

func (h *host) locked(ctx context.Context, f func() error) error {
	return state.WithLock(ctx, h.opts.Config.LockPath, func() error {
		if err := h.recover(ctx); err != nil {
			return errors.Join(err, h.command(ctx, "stop"))
		}
		if err := h.load(); err != nil {
			return errors.Join(err, h.command(ctx, "stop"))
		}
		return f()
	})
}

func optionalJSON(path string, value any) error {
	err := state.ReadJSON(path, value)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (h *host) load() error {
	c := h.opts.Config
	h.config = Object{"log": Object{"level": "info"}, "inbounds": []any{}}
	h.db = database{Users: map[string]*User{}, Counters: map[string]int64{}}
	h.meta = map[string]nodeMeta{}
	h.routing = routing{}
	h.central = centralState{}
	for _, pair := range []struct {
		path  string
		value any
	}{
		{c.ConfigPath, &h.config}, {c.UserDBPath, &h.db}, {c.MetaPath, &h.meta},
		{c.MetaPath + ".routing", &h.routing}, {c.UserDBPath + ".central", &h.central},
	} {
		if err := optionalJSON(pair.path, pair.value); err != nil {
			return err
		}
	}
	if h.config == nil || h.db.Users == nil || h.meta == nil {
		return errors.New("invalid null node state")
	}
	if h.db.Counters == nil {
		h.db.Counters = map[string]int64{}
	}
	if h.db.Users["admin"] == nil {
		h.db.Users["admin"] = &User{Enabled: true, Nodes: []string{"*"}, ExpireAt: "0"}
	}
	for name, u := range h.db.Users {
		if !validName(name) || u == nil {
			return errors.New("invalid user database")
		}
		if u.Up < 0 || u.Up > maxSafe || u.Down < 0 || u.Down > maxSafe || u.QuotaBytes < 0 || u.QuotaBytes > maxSafe || u.Grant < 0 || u.Grant > maxSafe || u.Period < 0 || u.Period > maxSafe || u.ResetDay < 0 || u.ResetDay > 32 || u.ResetAnchor < 0 {
			return errors.New("invalid user accounting state")
		}
		if u.Credentials == nil {
			u.Credentials = map[string]Object{}
		}
		if u.CredentialAliases == nil {
			u.CredentialAliases = map[string][]Object{}
		}
		if !u.hasNativeExpiry {
			now, err := h.localNow()
			if err != nil {
				return err
			}
			if err := u.decodeExpiry(now.Location()); err != nil {
				return err
			}
		}
		if u.Expires < 0 || u.Expires > maxSafe || u.Manual < -maxSafe || u.Manual > maxSafe {
			return errors.New("invalid expiry or usage correction")
		}
		u.QuotaGB = float64(u.QuotaBytes) / (1 << 30)
		if u.Expires > 0 && (u.ExpireAt == "" || u.ExpireAt == "0") {
			u.ExpireAt = fmt.Sprint(u.Expires)
		}
		if name == "admin" {
			u.Up = 0
			u.Down = 0
			u.QuotaGB = 0
			u.QuotaBytes = 0
			u.Grant = 0
			u.Manual = 0
			u.ResetDay = 0
		}
	}
	return h.hydrateCredentials(false)
}

func validName(s string) bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

func object(v any) Object {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return Object{}
}
func text(v any) string { s, _ := v.(string); return s }
func list(v any) []any  { a, _ := v.([]any); return a }
func number(v any) int64 {
	switch n := v.(type) {
	case json.Number:
		i, _ := n.Int64()
		return i
	case int:
		return int64(n)
	case int64:
		return n
	case float64:
		return int64(n)
	}
	return 0
}
func sortedUsers(db database) []string {
	keys := make([]string, 0, len(db.Users))
	for n := range db.Users {
		keys = append(keys, n)
	}
	sort.Strings(keys)
	return keys
}
func contains(a []string, s string) bool {
	for _, v := range a {
		if v == s || v == "*" {
			return true
		}
	}
	return false
}
func (h *host) managed() bool { return h.central.InstanceID != "" }
func (h *host) active(name, tag string) bool {
	u := h.db.Users[name]
	if u == nil || !u.Enabled || !contains(u.Nodes, tag) {
		return false
	}
	if name == "admin" {
		return true
	}
	if h.db.StatsBlocked || h.db.ProbeRequired || u.Expires > 0 && h.opts.Now().Unix() >= u.Expires {
		return false
	}
	for _, p := range h.db.Uncertain {
		if p.Username == name && p.Period == u.Period {
			return false
		}
	}
	used := sum(u.Up, u.Down)
	if h.managed() {
		return h.central.ServerID != "" && u.Granted && u.Period >= 1 && used < u.Grant && used < u.QuotaBytes
	}
	if u.Manual >= 0 {
		used = sum(used, u.Manual)
	} else {
		used += u.Manual
		if used < 0 {
			used = 0
		}
	}
	return u.QuotaBytes == 0 || used < u.QuotaBytes
}
func sum(a, b int64) int64 {
	if a < 0 || b < 0 || a > maxSafe-b {
		return maxSafe
	}
	return a + b
}

// The central wire contract deliberately uses a lower ceiling than 2^53-1.
const maxSafe int64 = 1000000000000000

func (h *host) execute(ctx context.Context, name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	return h.opts.Command(ctx, name, args...)
}

func (h *host) command(ctx context.Context, args ...string) error {
	_, err := h.execute(ctx, "systemctl", append(args, "sing-box.service")...)
	if err != nil {
		return fmt.Errorf("systemctl %s failed", strings.Join(args, " "))
	}
	return nil
}

func (h *host) stopUncertain(ctx context.Context, cause error) error {
	stopErr := h.command(ctx, "stop")
	if err := h.load(); err != nil {
		return errors.Join(cause, stopErr, err)
	}
	h.db.StatsBlocked = true
	h.db.RuntimeStopped = stopErr == nil
	quarantine(&h.db, nil)
	return errors.Join(cause, stopErr, state.WriteJSON(h.opts.Config.UserDBPath, h.db))
}
