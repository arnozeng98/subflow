package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/arnozeng98/subflow/internal/settings"
	"github.com/arnozeng98/subflow/internal/state"
)

func fixture(t *testing.T) settings.Config {
	t.Helper()
	c, err := settings.Defaults()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	c.UserDBPath = filepath.Join(dir, "users.json")
	c.ConfigPath = filepath.Join(dir, "config.json")
	c.MetaPath = filepath.Join(dir, "meta.json")
	c.LockPath = filepath.Join(dir, "state.lock")
	c.APIToken = "test-only-token"
	c.PublicIP = "203.0.113.10"
	c.VlessWSDomain = "ws.example.test"
	for path, content := range map[string]string{
		c.UserDBPath: `{"users":{
			"alice":{"enabled":true,"quota_gb":"100","used_up_bytes":9007199254740993,"used_down_bytes":2,"expire_at":0},
			"bob":{"enabled":true},
			"disabled":{"enabled":false},
			"admin":{"enabled":true},
			"empty":{"enabled":true}
		}}`,
		c.ConfigPath: `{"inbounds":[
			{"tag":"reality-in","type":"vless","listen_port":443,"tls":{"reality":{"enabled":true}},"users":[
				{"name":"tokyo@alice","uuid":"alice-uuid"},
				{"name":"tokyo@bob","uuid":"bob-secret"},
				{"name":"tokyo@disabled","uuid":"disabled-secret"},
				{"name":"tokyo","uuid":"admin-secret"}
			]},
			{"tag":"socks-in","type":"socks","users":[{"username":"local@alice","password":"alice-password"}]},
			{"tag":"untagged-users","type":"socks","users":[{"password":"unattributed-secret"}]}
		]}`,
		c.MetaPath: `{"reality-in":{"public_key":"public-key","private_key":"private-secret"},"other":{"public_key":"other-key"}}`,
	} {
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return c
}

func request(c settings.Config, path, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodGet, path, nil)
	if token != "" {
		r.Header.Set("Authorization", token)
	}
	w := httptest.NewRecorder()
	NewHandler(c, slog.New(slog.NewTextHandler(io.Discard, nil))).ServeHTTP(w, r)
	return w
}

func TestAuthenticationAndRoutes(t *testing.T) {
	c := fixture(t)
	for _, tc := range []struct {
		path, token string
		status      int
	}{
		{"/healthz", "", 403},
		{"/healthz", "Bearer wrong", 403},
		{"/healthz", "Bearer " + c.APIToken, 200},
		{"/internal/raw/alice", c.APIToken, 403},
		{"/internal/raw/alice", "Bearer " + c.APIToken, 200},
		{"/internal/raw/missing", "Bearer " + c.APIToken, 404},
		{"/internal/raw/disabled", "Bearer " + c.APIToken, 404},
		{"/internal/raw/empty", "Bearer " + c.APIToken, 404},
		{"/internal/raw/a%2Fb", "Bearer " + c.APIToken, 404},
		{"/internal/raw/alice/extra", "Bearer " + c.APIToken, 404},
		{"/unknown", "Bearer " + c.APIToken, 404},
	} {
		w := request(c, tc.path, tc.token)
		if w.Code != tc.status || w.Header().Get("Cache-Control") != "no-store" {
			t.Errorf("%s: status=%d, want %d; %s", tc.path, w.Code, tc.status, w.Body.String())
		}
	}
	c.APIToken = ""
	if w := request(c, "/healthz", "Bearer "); w.Code != 403 {
		t.Fatal("empty token accepted")
	}
}

func TestRawPayloadIsolationAndShape(t *testing.T) {
	c := fixture(t)
	w := request(c, "/internal/raw/alice", "Bearer "+c.APIToken)
	if w.Code != 200 {
		t.Fatalf("%d: %s", w.Code, w.Body.String())
	}
	for _, secret := range []string{"bob-secret", "admin-secret", "disabled-secret", "private-secret", "unattributed-secret", "other-key"} {
		if strings.Contains(w.Body.String(), secret) {
			t.Errorf("response leaked %s", secret)
		}
	}
	var payload Payload
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Username != "alice" || len(payload.Inbounds) != 2 ||
		payload.Usage.UsedUpBytes != 9007199254740993 || payload.Usage.QuotaGB != 100 ||
		payload.Usage.ExpireAt != "0" || payload.Meta["reality-in"].PublicKey != "public-key" ||
		payload.WSDomains.Vless != c.VlessWSDomain || payload.PublicIP != c.PublicIP {
		t.Fatalf("payload contract changed: %+v", payload)
	}
	admin := request(c, "/internal/raw/admin", "Bearer "+c.APIToken)
	if admin.Code != 200 || !strings.Contains(admin.Body.String(), "admin-secret") || strings.Contains(admin.Body.String(), "alice-uuid") {
		t.Fatal("legacy administrator naming changed")
	}
	c.IncludeDisabledUsers = true
	if w := request(c, "/internal/raw/disabled", "Bearer "+c.APIToken); w.Code != 200 {
		t.Fatal("include disabled override ignored")
	}
}

func TestCorruptStateIsServiceFailure(t *testing.T) {
	c := fixture(t)
	if err := os.WriteFile(c.ConfigPath, []byte("{broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if w := request(c, "/internal/raw/alice", "Bearer "+c.APIToken); w.Code != 503 {
		t.Fatalf("data corruption masqueraded as user absence: %d", w.Code)
	}
}

func TestUsernameContract(t *testing.T) {
	for _, tc := range []struct {
		value string
		valid bool
	}{
		{" alice_1-ABC ", true}, {"", false}, {"../alice", false},
		{"用户", false}, {strings.Repeat("a", 64), true}, {strings.Repeat("a", 65), false},
	} {
		if _, ok := NormalizeUsername(tc.value); ok != tc.valid {
			t.Errorf("username %q: valid=%v", tc.value, ok)
		}
	}
}

func TestSharedContractFixture(t *testing.T) {
	c := fixture(t)
	var expected Payload
	path := filepath.Join("..", "..", "contracts", "fixtures", "raw-alice.json")
	if err := state.ReadJSON(path, &expected); err != nil {
		t.Fatal(err)
	}
	c.PublicIP, c.VlessWSDomain, c.VmessWSDomain = expected.PublicIP, expected.WSDomains.Vless, expected.WSDomains.Vmess
	for path, value := range map[string]any{
		c.ConfigPath: map[string]any{"inbounds": expected.Inbounds},
		c.UserDBPath: map[string]any{"users": map[string]Usage{"alice": expected.Usage}},
		c.MetaPath:   expected.Meta,
	} {
		if err := state.WriteJSON(path, value); err != nil {
			t.Fatal(err)
		}
	}
	w := request(c, "/internal/raw/alice", "Bearer "+c.APIToken)
	if w.Code != 200 {
		t.Fatalf("contract request: %d %s", w.Code, w.Body.String())
	}
	var got Payload
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	actualJSON, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	expectedJSON, err := json.Marshal(expected)
	if err != nil {
		t.Fatal(err)
	}
	var actualDocument, expectedDocument any
	if err := json.Unmarshal(actualJSON, &actualDocument); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(expectedJSON, &expectedDocument); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actualDocument, expectedDocument) {
		t.Fatalf("shared contract changed:\ngot %s\nwant %s", actualJSON, expectedJSON)
	}
}

func TestServerLifecycle(t *testing.T) {
	c := fixture(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- ServeListener(ctx, listener, c, slog.New(slog.NewTextHandler(io.Discard, nil)))
	}()
	client := &http.Client{Timeout: 3 * time.Second}
	r, err := http.NewRequest(http.MethodGet, "http://"+listener.Addr().String()+"/healthz", nil)
	if err != nil {
		t.Fatal(err)
	}
	r.Header.Set("Authorization", "Bearer "+c.APIToken)
	resp, err := client.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil || resp.StatusCode != 200 || string(body) != "ok" {
		t.Fatalf("health: %d %q %v", resp.StatusCode, body, err)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("server did not shut down")
	}
}
