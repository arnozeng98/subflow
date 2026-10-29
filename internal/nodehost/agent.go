package nodehost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/arnozeng98/subflow/internal/state"
)

type Report struct {
	Username string `json:"username"`
	Period   int64  `json:"period"`
	Up       int64  `json:"up"`
	Down     int64  `json:"down"`
}
type Policy struct {
	Username   string   `json:"username"`
	Enabled    bool     `json:"enabled"`
	QuotaBytes int64    `json:"quota_bytes"`
	Period     int64    `json:"period"`
	GrantBytes int64    `json:"grant_bytes"`
	ExpiresAt  int64    `json:"expires_at"`
	Nodes      []string `json:"nodes"`
}
type SyncRequest struct {
	Version         int                   `json:"version"`
	Sequence        int64                 `json:"sequence"`
	AppliedRevision int64                 `json:"applied_revision"`
	Reports         []Report              `json:"reports"`
	Payloads        map[string]RawPayload `json:"payloads"`
	Inventory       []Inventory           `json:"inventory"`
}
type Inventory struct {
	Tag  string `json:"tag"`
	Type string `json:"type"`
}
type SyncResponse struct {
	Version  int      `json:"version"`
	Revision int64    `json:"revision"`
	Users    []Policy `json:"users"`
}
type centralState struct {
	URL             string        `json:"url"`
	InstanceID      string        `json:"instance_id"`
	AgentToken      string        `json:"agent_token"`
	EnrollmentToken string        `json:"enrollment_token,omitempty"`
	ServerID        string        `json:"server_id"`
	Sequence        int64         `json:"sequence"`
	AppliedRevision int64         `json:"applied_revision"`
	Pending         []byte        `json:"pending,omitempty"`
	Response        *SyncResponse `json:"response,omitempty"`
	ReportCursor    int           `json:"report_cursor,omitempty"`
}

func origin(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || u.Opaque != "" {
		return "", errors.New("central URL must be an HTTPS origin without credentials, path, query or fragment")
	}
	if strings.ContainsAny(u.Host, "\r\n\\") {
		return "", errors.New("invalid central origin")
	}
	return "https://" + u.Host, nil
}

func (h *host) post(ctx context.Context, path string, body []byte, dest any, enroll bool) error {
	client := &http.Client{Timeout: 20 * time.Second}
	if h.opts.HTTPClient != nil {
		*client = *h.opts.HTTPClient
	}
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	if client.Timeout <= 0 {
		client.Timeout = 20 * time.Second
	}
	req, err := http.NewRequestWithContext(ctx, "POST", h.central.URL+path, bytes.NewReader(body))
	if err != nil {
		return errors.New("central request creation failed")
	}
	req.Header.Set("Content-Type", "application/json")
	if !enroll {
		req.Header.Set("Authorization", "Bearer "+h.central.AgentToken)
		req.Header.Set("X-Subflow-Server", h.central.ServerID)
	}
	resp, err := client.Do(req)
	if err != nil {
		return errors.New("central request failed (details redacted)")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("central rejected request (HTTP %d; details redacted)", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return errors.New("central response read failed")
	}
	if err := json.Unmarshal(b, dest); err != nil {
		return errors.New("invalid central response")
	}
	return nil
}

func (h *host) enroll(ctx context.Context, rawURL, tokenPath string) error {
	base, err := origin(rawURL)
	if err != nil {
		return err
	}
	return h.locked(ctx, func() error {
		if h.central.ServerID != "" {
			return errors.New("already enrolled")
		}
		if h.central.InstanceID == "" {
			token, err := os.ReadFile(tokenPath)
			if err != nil {
				return errors.New("cannot read enrollment token file")
			}
			tokenText := strings.TrimSpace(string(token))
			if tokenText == "" || len(tokenText) > 256 {
				return errors.New("invalid enrollment token file")
			}
			id, e := randomHex(16)
			if e != nil {
				return e
			}
			credential, e := randomHex(32)
			if e != nil {
				return e
			}
			h.central = centralState{URL: base, InstanceID: id, AgentToken: credential, EnrollmentToken: tokenText}
		} else if h.central.URL != base {
			return errors.New("pending enrollment origin cannot be changed")
		}
		if err := state.WriteJSON(h.opts.Config.UserDBPath+".central", h.central); err != nil {
			return err
		}
		request := Object{"version": 1, "token": h.central.EnrollmentToken, "instance_id": h.central.InstanceID, "agent_token": h.central.AgentToken}
		b, _ := json.Marshal(request)
		var response struct {
			Version  int    `json:"version"`
			ServerID string `json:"server_id"`
		}
		if err := h.post(ctx, "/agent/enroll", b, &response, true); err != nil {
			return err
		}
		if response.Version != 1 || response.ServerID == "" || len(response.ServerID) > 256 || strings.ContainsAny(response.ServerID, "\r\n") {
			return errors.New("invalid enrollment response")
		}
		h.central.ServerID = response.ServerID
		h.central.EnrollmentToken = ""
		if err := state.WriteJSON(h.opts.Config.UserDBPath+".central", h.central); err != nil {
			return err
		}
		// Enrollment removes all standalone allowances before any central grant.
		err := h.mutate(ctx, func() error {
			for name, u := range h.db.Users {
				if name != "admin" {
					u.Grant = 0
				}
			}
			return nil
		})
		if err != nil {
			return errors.Join(err, h.command(ctx, "stop"))
		}
		return nil
	})
}

func (h *host) reports() []Report {
	reports := append([]Report{}, h.db.Archive...)
	for _, name := range sortedUsers(h.db) {
		if name != "admin" {
			u := h.db.Users[name]
			if u.Granted {
				reports = append(reports, Report{name, u.Period, u.Up, u.Down})
			}
		}
	}
	sort.Slice(reports, func(i, j int) bool {
		if reports[i].Username != reports[j].Username {
			return reports[i].Username < reports[j].Username
		}
		return reports[i].Period < reports[j].Period
	})
	return reports
}

func (h *host) sync(ctx context.Context) error {
	var sampleErr error
	var pending []byte
	var requestState centralState
	err := h.locked(ctx, func() error {
		if h.db.RestartPrepared {
			return ErrRestartPrepared
		}
		if h.central.ServerID == "" {
			return errors.New("agent is not enrolled")
		}
		if _, err := origin(h.central.URL); err != nil {
			return err
		}
		// Failed statistics are not a reason to stop contacting central: the
		// service is already stopped and its last durable reports remain valid.
		sampleErr = h.sample(ctx)
		if len(h.central.Pending) == 0 {
			if h.central.Sequence >= maxSafe {
				return errors.New("agent sequence exhausted")
			}
			reports, nextCursor := reportBatch(h.reports(), h.central.ReportCursor)
			request := SyncRequest{Version: 1, Sequence: h.central.Sequence + 1, AppliedRevision: h.central.AppliedRevision, Reports: reports, Payloads: map[string]RawPayload{}, Inventory: []Inventory{}}
			for _, v := range list(h.config["inbounds"]) {
				in := object(v)
				request.Inventory = append(request.Inventory, Inventory{text(in["tag"]), text(in["type"])})
			}
			for _, name := range sortedUsers(h.db) {
				if p, err := h.payload(name); err == nil {
					request.Payloads[name] = p
				}
				if len(request.Inventory) > 128 || len(request.Payloads) > 128 {
					return errors.New("central permits at most 128 inventory entries and payload owners per node")
				}
			}
			b, err := json.Marshal(request)
			if err != nil {
				return err
			}
			h.central.Pending = b
			h.central.Sequence = request.Sequence
			h.central.ReportCursor = nextCursor
			if err := state.WriteJSON(h.opts.Config.UserDBPath+".central", h.central); err != nil {
				return err
			}
		}
		pending = append([]byte{}, h.central.Pending...)
		requestState = clone(h.central)
		return nil
	})
	if err != nil {
		return err
	}
	if requestState.Response == nil {
		transportHost := newHost(h.opts, h.out, h.errOut)
		transportHost.central = requestState
		var response SyncResponse
		if err := transportHost.post(ctx, "/agent/sync", pending, &response, false); err != nil {
			return errors.Join(sampleErr, err)
		}
		requestState.Response = &response
	}
	// Network latency never holds the state lock, so accounting and local
	// protocol changes remain possible while central is disconnected.
	return h.locked(ctx, func() error {
		if h.db.RestartPrepared {
			return ErrRestartPrepared
		}
		if !bytes.Equal(h.central.Pending, pending) {
			return errors.New("sync request was superseded while in flight")
		}
		if h.central.Response == nil {
			if err := h.validateResponse(*requestState.Response); err != nil {
				return err
			}
			h.central.Response = requestState.Response
			if err := state.WriteJSON(h.opts.Config.UserDBPath+".central", h.central); err != nil {
				return err
			}
		}
		response := *h.central.Response
		if err := h.validateResponse(response); err != nil {
			return err
		}
		err := h.mutate(ctx, func() error {
			var sent SyncRequest
			if err := json.Unmarshal(h.central.Pending, &sent); err != nil {
				return err
			}
			h.ackArchives(sent.Reports)
			present := map[string]bool{}
			for _, p := range response.Users {
				present[p.Username] = true
				u := h.db.Users[p.Username]
				if u == nil {
					u = &User{Credentials: map[string]Object{}, ExpireAt: "0"}
					h.db.Users[p.Username] = u
				}
				if p.Username != "admin" && (!u.Granted || u.Period != p.Period) {
					if u.Granted {
						h.archive(Report{p.Username, u.Period, u.Up, u.Down})
					}
					u.Up = 0
					u.Down = 0
				}
				u.Enabled = p.Enabled
				u.Nodes = p.Nodes
				u.Expires = p.ExpiresAt
				u.ExpireAt = fmt.Sprint(p.ExpiresAt)
				u.Period = p.Period
				if p.Username != "admin" {
					u.QuotaBytes = p.QuotaBytes
					u.QuotaGB = float64(p.QuotaBytes) / (1 << 30)
					u.Grant = p.GrantBytes
					u.Granted = true
					u.Manual = 0
				}
			}
			for name, u := range h.db.Users {
				if !present[name] {
					if name == "admin" {
						u.Enabled = false
						continue
					}
					// Keep a disabled tombstone and its credentials/counters:
					// revocation cannot erase unacknowledged consumption.
					u.Enabled = false
					u.Grant = 0
					u.Nodes = []string{}
				}
			}
			h.central.AppliedRevision = response.Revision
			h.central.Pending = nil
			h.central.Response = nil
			return nil
		})
		if err != nil {
			// A received revocation must not leave an older permissive
			// runtime serving while a candidate/configuration error persists.
			err = h.stopUncertain(ctx, err)
		}
		return errors.Join(sampleErr, err)
	})
}

func (h *host) validateResponse(r SyncResponse) error {
	if r.Version != 1 || r.Revision < 0 || r.Revision > maxSafe || r.Revision < h.central.AppliedRevision {
		return errors.New("invalid or stale central revision")
	}
	seen := map[string]bool{}
	payloadOwners := 0
	for _, p := range r.Users {
		if !validName(p.Username) || seen[p.Username] || p.Period < 0 || p.Period > maxSafe || p.ExpiresAt < 0 || p.ExpiresAt > maxSafe {
			return errors.New("invalid central user policy")
		}
		seen[p.Username] = true
		if len(p.Nodes) > 0 {
			payloadOwners++
		}
		if p.Username != "admin" {
			if p.Period < 1 {
				return errors.New("ordinary central periods start at one")
			}
			if p.QuotaBytes < 0 || p.QuotaBytes > maxSafe || p.GrantBytes < 0 || p.GrantBytes > maxSafe {
				return errors.New("invalid central allowance")
			}
			if old := h.db.Users[p.Username]; old != nil && old.Granted {
				if p.Period < old.Period {
					return errors.New("stale central period")
				}
				if p.Period == old.Period && p.Enabled && p.GrantBytes < old.Grant {
					return errors.New("regressed central grant")
				}
			}
		}
		for _, tag := range p.Nodes {
			if tag != "*" && !validName(tag) {
				return errors.New("invalid central node permission")
			}
		}
	}
	if payloadOwners > 128 {
		return errors.New("central permits at most 128 payload owners per node")
	}
	if !seen["admin"] {
		return errors.New("central policy must include admin")
	}
	return nil
}

func reportBatch(reports []Report, cursor int) ([]Report, int) {
	if len(reports) <= 128 {
		return reports, 0
	}
	if cursor < 0 {
		cursor = 0
	}
	cursor %= len(reports)
	batch := make([]Report, 128)
	for i := range batch {
		batch[i] = reports[(cursor+i)%len(reports)]
	}
	return batch, (cursor + 128) % len(reports)
}

func (h *host) archive(r Report) {
	if r.Username == "admin" {
		return
	}
	for i, v := range h.db.Archive {
		if v.Username == r.Username && v.Period == r.Period {
			h.db.Archive[i].Up = sum(v.Up, r.Up)
			h.db.Archive[i].Down = sum(v.Down, r.Down)
			return
		}
	}
	h.db.Archive = append(h.db.Archive, r)
}
func (h *host) ackArchives(sent []Report) {
	keep := []Report{}
	for _, r := range h.db.Archive {
		acked := false
		for _, s := range sent {
			if s.Username == r.Username && s.Period == r.Period && s.Up >= r.Up && s.Down >= r.Down {
				acked = true
				break
			}
		}
		if !acked {
			keep = append(keep, r)
		}
	}
	h.db.Archive = keep
}

func (h *host) enforce(ctx context.Context) error {
	return h.locked(ctx, func() error {
		if h.db.RestartPrepared {
			if !h.db.RuntimeStopped {
				return h.prepareRestart(ctx)
			}
			return nil
		}
		if err := h.sample(ctx); err != nil {
			return err
		}
		due, err := h.dueResets()
		if err != nil {
			return err
		}
		if len(due) > 0 {
			if err := h.mutate(ctx, func() error { return nil }); err != nil {
				return h.stopUncertain(ctx, err)
			}
			return nil
		}
		before, _ := json.Marshal(h.config)
		if err := h.render(); err != nil {
			return err
		}
		after, _ := json.Marshal(h.config)
		if bytes.Equal(before, after) {
			return nil
		}
		if err := h.mutate(ctx, func() error { return nil }); err != nil {
			fmt.Fprintln(h.errOut, "ERROR: quota enforcement apply failed; stopping service")
			return h.stopUncertain(ctx, err)
		}
		return nil
	})
}

func (h *host) agentRun(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	if err := h.bootstrap(ctx); err != nil {
		fmt.Fprintln(h.errOut, "ERROR: startup accounting/probe:", err)
	}
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	done := make(chan error, 1)
	running := false
	defer func() {
		cancel()
		if running {
			<-done
		}
		stopCtx, stopCancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer stopCancel()
		if err := h.run(stopCtx, []string{"system", "stop"}); err != nil {
			fmt.Fprintln(h.errOut, "ERROR: agent shutdown:", err)
		}
	}()
	next := time.Time{}
	for {
		if err := h.enforce(ctx); err != nil {
			fmt.Fprintln(h.errOut, "ERROR: local enforcement:", err)
		}
		if !running && h.central.ServerID != "" && !h.opts.Now().Before(next) {
			running = true
			worker := newHost(h.opts, h.out, h.errOut)
			go func() { done <- worker.sync(ctx) }()
			next = h.opts.Now().Add(time.Minute)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-done:
			running = false
			if err != nil {
				fmt.Fprintln(h.errOut, "ERROR: central synchronization:", err)
			}
		case <-tick.C:
		}
	}
}
