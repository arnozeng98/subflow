package nodehost

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

type localCentralTransport struct {
	base     *url.URL
	mu       sync.Mutex
	requests []SyncRequest
}

func (transport *localCentralTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	copy := request.Clone(request.Context())
	target := *request.URL
	target.Scheme = transport.base.Scheme
	target.Host = transport.base.Host
	copy.URL = &target
	copy.Host = ""
	if request.URL.Path == "/agent/sync" {
		body, err := io.ReadAll(request.Body)
		if err != nil {
			return nil, err
		}
		request.Body.Close()
		copy.Body = io.NopCloser(bytes.NewReader(body))
		var decoded SyncRequest
		if err := json.Unmarshal(body, &decoded); err != nil {
			return nil, err
		}
		transport.mu.Lock()
		transport.requests = append(transport.requests, decoded)
		transport.mu.Unlock()
	}
	return http.DefaultTransport.RoundTrip(copy)
}

// TestAgentCentralIntegration talks only to an explicitly provided local Worker.
// The HTTP rewrite is test-only; production enrollment still requires HTTPS.
func TestAgentCentralIntegration(t *testing.T) {
	rawURL, token := os.Getenv("SUBFLOW_TEST_CENTRAL_URL"), os.Getenv("SUBFLOW_TEST_ENROLLMENT_TOKEN")
	if rawURL == "" || token == "" {
		t.Skip("set SUBFLOW_TEST_CENTRAL_URL and SUBFLOW_TEST_ENROLLMENT_TOKEN")
	}
	base, err := url.Parse(rawURL)
	if err != nil {
		t.Fatal("invalid local central URL")
	}
	ip := net.ParseIP(base.Hostname())
	approvedRelay := ip != nil && ip.Equal(net.ParseIP("172.30.48.1"))
	if base.Scheme != "http" || (base.Hostname() != "localhost" && (ip == nil || !ip.IsLoopback()) && !approvedRelay) || base.User != nil || base.RawQuery != "" || base.Fragment != "" || (base.Path != "" && base.Path != "/") {
		t.Fatal("integration transport permits only loopback or the authorized WSL relay 172.30.48.1")
	}
	name := os.Getenv("SUBFLOW_TEST_USERNAME")
	if name == "" {
		name = "alice"
	}
	if !validName(name) || name == "admin" {
		t.Fatal("invalid integration fixture username")
	}
	h := testHost(t)
	addNode(t, h, "socks", "integration", 1080)
	saveHost(t, h)
	tokenPath := filepath.Join(filepath.Dir(h.opts.Config.UserDBPath), "enrollment-token")
	if err := os.WriteFile(tokenPath, []byte(token), 0600); err != nil {
		t.Fatal(err)
	}
	transport := &localCentralTransport{base: base}
	h.opts.HTTPClient = &http.Client{Transport: transport}
	up, down := int64(0), int64(0)
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		return []Stat{{"user>>>integration@" + name + ">>>traffic>>>uplink", up}, {"user>>>integration@" + name + ">>>traffic>>>downlink", down}, {"user>>>integration@admin>>>traffic>>>uplink", 999999}}, nil
	}
	ctx := context.Background()
	if err := h.run(ctx, []string{"agent", "enroll", "--url", "https://central.integration.invalid", "--token-file", tokenPath}); err != nil {
		t.Fatal(err)
	}
	bytesOnDisk, err := os.ReadFile(h.opts.Config.UserDBPath + ".central")
	if err != nil {
		t.Fatal(err)
	}
	var persisted map[string]json.RawMessage
	if err := json.Unmarshal(bytesOnDisk, &persisted); err != nil {
		t.Fatal(err)
	}
	var serverID string
	if err := json.Unmarshal(persisted["server_id"], &serverID); err != nil || serverID == "" || serverID != h.central.ServerID {
		t.Fatal("server_id is not a nonempty top-level central-state field")
	}
	if err := h.run(ctx, []string{"sync"}); err != nil {
		t.Fatal(err)
	}
	firstRevision := h.central.AppliedRevision
	ordinary := h.db.Users[name]
	if ordinary == nil || !ordinary.Enabled || !ordinary.Granted || ordinary.Grant < 6144 || !contains(ordinary.Nodes, "integration") {
		t.Fatalf("fixture must grant enabled user %s at least 6144 bytes on integration or *", name)
	}
	up = 4096
	down = 2048
	if err := h.run(ctx, []string{"agent", "sync"}); err != nil {
		t.Fatal(err)
	}
	transport.mu.Lock()
	requests := append([]SyncRequest{}, transport.requests...)
	transport.mu.Unlock()
	if len(requests) != 2 || requests[0].Sequence != 1 || requests[1].Sequence != 2 || len(requests[0].Reports) != 0 || requests[0].AppliedRevision != 0 {
		t.Fatal("first-sync or sequence contract mismatch")
	}
	if requests[1].AppliedRevision != firstRevision {
		t.Fatal("reported revision is not the prior applied response revision")
	}
	if _, ok := requests[0].Payloads["admin"]; !ok {
		t.Fatal("first sync omitted admin payload")
	}
	if _, ok := requests[0].Payloads[name]; ok {
		t.Fatal("unassigned ordinary identity existed before central response")
	}
	if requests[1].Payloads[name].SchemaVersion != 1 || requests[1].Payloads["admin"].SchemaVersion != 1 {
		t.Fatal("second sync omitted typed ordinary/admin payloads")
	}
	found := false
	for _, report := range requests[1].Reports {
		if report.Username == "admin" {
			t.Fatal("admin must never be reported")
		}
		if report.Username == name {
			found = true
			if report.Up != 4096 || report.Down != 2048 || report.Period < 1 {
				t.Fatal("counter report is not cumulative since its granted period")
			}
		}
	}
	if !found || h.db.Users[name].Up != 4096 || h.db.Users[name].Down != 2048 || h.db.Users["admin"].Up != 0 || h.db.Users["admin"].Down != 0 {
		t.Fatal("usage accounting mismatch")
	}
	t.Logf("local Worker round trip passed: user=%s, period=%d, prior_revision=%d, applied_revision=%d", name, h.db.Users[name].Period, firstRevision, h.central.AppliedRevision)
}
