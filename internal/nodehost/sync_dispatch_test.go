package nodehost

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRootSyncMaintainsStandaloneQuotaAndCalendar(t *testing.T) {
	h := testHost(t)
	h.opts.Config.BusinessTimezone = "UTC"
	now := time.Date(2026, time.January, 15, 12, 0, 0, 0, time.UTC)
	h.opts.Now = func() time.Time { return now }
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	h.db.Users["alice"].QuotaBytes = 100
	counter := int64(150)
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		return []Stat{{"user>>>edge@alice>>>traffic>>>uplink", counter}}, nil
	}
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "systemctl" && len(args) > 0 && args[0] == "restart" {
			counter = 0
		}
		return nil, nil
	}
	saveHost(t, h)
	if err := h.run(context.Background(), []string{"sync"}); err != nil {
		t.Fatal("standalone timer failed", err)
	}
	if h.db.Users["alice"].Up != 150 || h.active("alice", "edge") {
		t.Fatal("standalone sync did not account/enforce quota")
	}
	h.db.Users["alice"].ResetDay = 1
	h.db.Users["alice"].ResetAnchor = now.Unix()
	saveHost(t, h)
	now = time.Date(2026, time.February, 2, 12, 0, 0, 0, time.UTC)
	if err := h.run(context.Background(), []string{"sync"}); err != nil {
		t.Fatal(err)
	}
	if h.db.Users["alice"].Up != 0 || h.db.Users["alice"].LastReset != "2026-02-01" || !h.active("alice", "edge") {
		t.Fatal("standalone sync did not catch up monthly reset")
	}
	h.central.InstanceID = "pending-enrollment"
	saveHost(t, h)
	if err := h.run(context.Background(), []string{"sync"}); err != nil {
		t.Fatal("pending enrollment timer failed", err)
	}
	if h.active("alice", "edge") {
		t.Fatal("pending enrollment reopened ungranted ordinary traffic")
	}
}

func TestRootSyncRetainsEnrolledCentralDispatch(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "socks", "edge", 1080)
	calls := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/agent/sync" {
			t.Error("wrong central endpoint")
		}
		var request SyncRequest
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
		}
		if request.Sequence != 1 || len(request.Reports) != 0 {
			t.Error("unexpected first sync")
		}
		json.NewEncoder(w).Encode(SyncResponse{Version: 1, Revision: 3, Users: []Policy{{Username: "admin", Enabled: true, Period: 1, Nodes: []string{"*"}}}})
	}))
	defer server.Close()
	h.opts.HTTPClient = server.Client()
	h.central = centralState{URL: server.URL, ServerID: "server", InstanceID: "instance", AgentToken: strings.Repeat("a", 64)}
	saveHost(t, h)
	if err := h.run(context.Background(), []string{"sync"}); err != nil {
		t.Fatal(err)
	}
	if calls != 1 || h.central.AppliedRevision != 3 {
		t.Fatal("enrolled root sync did not synchronize centrally")
	}
}
