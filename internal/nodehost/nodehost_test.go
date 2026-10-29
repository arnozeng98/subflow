package nodehost

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/arnozeng98/subflow/internal/settings"
	"github.com/arnozeng98/subflow/internal/state"
)

func testHost(t *testing.T) *host {
	t.Helper()
	dir, err := os.MkdirTemp(".", "nodehost-test-")
	if err != nil {
		t.Fatal(err)
	}
	absolute, err := filepath.Abs(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(absolute) })
	c := settings.Config{ConfigPath: filepath.Join(absolute, "config.json"), UserDBPath: filepath.Join(absolute, "users.json"), MetaPath: filepath.Join(absolute, "meta.json"), LockPath: filepath.Join(absolute, "lock"), PublicIP: "192.0.2.1"}
	h := newHost(Options{Config: c, Now: func() time.Time { return time.Unix(1800000000, 0) }, Command: func(context.Context, string, ...string) ([]byte, error) { return nil, nil }, Stats: func(context.Context, string) ([]Stat, error) { return []Stat{}, nil }}, io.Discard, io.Discard)
	if err := h.load(); err != nil {
		t.Fatal(err)
	}
	return h
}
func addNode(t *testing.T, h *host, protocol, tag string, port int) {
	t.Helper()
	if err := h.addProtocol(protocol, tag, port, "example.com", "/ws"); err != nil {
		t.Fatal(err)
	}
	if err := h.render(); err != nil {
		t.Fatal(err)
	}
}
func ordinary(h *host, name string) {
	h.db.Users[name] = &User{Enabled: true, Nodes: []string{"*"}, Credentials: map[string]Object{}, ExpireAt: "0"}
}
func saveHost(t *testing.T, h *host) {
	t.Helper()
	for _, p := range []struct {
		path string
		v    any
	}{{h.opts.Config.ConfigPath, h.config}, {h.opts.Config.UserDBPath, h.db}, {h.opts.Config.MetaPath, h.meta}, {h.opts.Config.UserDBPath + ".central", h.central}} {
		if e := state.WriteJSON(p.path, p.v); e != nil {
			t.Fatal(e)
		}
	}
}

func TestProtocolsCredentialsAndIsolation(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	ordinary(h, "bob")
	for i, p := range Protocols {
		addNode(t, h, p, p, 20000+i)
	}
	before := clone(h.config)
	beforeCredentials := clone(h.db.Users["alice"].Credentials)
	h.db.Users["bob"].Enabled = false
	h.db.Users["alice"].Nodes = []string{"socks", "vless-reality"}
	if err := h.render(); err != nil {
		t.Fatal(err)
	}
	for _, v := range list(h.config["inbounds"]) {
		in := object(v)
		tag := text(in["tag"])
		for _, raw := range list(in["users"]) {
			user := object(raw)
			id := text(user["name"])
			if id == "" {
				id = text(user["username"])
			}
			if strings.HasSuffix(id, "@bob") {
				t.Fatal("disabled identity present")
			}
			if strings.HasSuffix(id, "@alice") && tag != "socks" && tag != "vless-reality" {
				t.Fatal("unauthorized identity present")
			}
		}
	}
	if !reflect.DeepEqual(beforeCredentials, h.db.Users["alice"].Credentials) {
		t.Fatal("credentials unexpectedly rotated")
	}
	beforeTLS, _ := json.Marshal(object(list(before["inbounds"])[0])["tls"])
	afterTLS, _ := json.Marshal(object(list(h.config["inbounds"])[0])["tls"])
	if !bytes.Equal(beforeTLS, afterTLS) {
		t.Fatal("TLS mutated")
	}
	rules := list(object(h.config["route"])["rules"])
	if object(rules[len(rules)-1])["action"] != "reject" {
		t.Fatal("missing terminal reject")
	}
	first := object(list(h.config["inbounds"])[0])
	private, e := base64.RawURLEncoding.DecodeString(text(object(object(first["tls"])["reality"])["private_key"]))
	if e != nil {
		t.Fatal(e)
	}
	key, e := ecdh.X25519().NewPrivateKey(private)
	if e != nil {
		t.Fatal(e)
	}
	if base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()) != h.meta["vless-reality"].PublicKey {
		t.Fatal("Reality key pair mismatch")
	}
}

func TestSOCKSDisabledNeverAnonymous(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "socks", "socks", 1080)
	h.db.Users["admin"].Enabled = false
	if err := h.render(); err != nil {
		t.Fatal(err)
	}
	in := object(list(h.config["inbounds"])[0])
	users := list(in["users"])
	if len(users) != 1 || !strings.HasPrefix(text(object(users[0])["username"]), "disabled-") {
		t.Fatal("empty SOCKS auth permits anonymous")
	}
	before := clone(h.config)
	if err := h.render(); err != nil {
		t.Fatal(err)
	}
	b1, _ := json.Marshal(before)
	b2, _ := json.Marshal(h.config)
	if !bytes.Equal(b1, b2) {
		t.Fatal("disabled rendering must be stable")
	}
}

func TestExportWhitelist(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "vless-reality", "reality", 443)
	in := object(list(h.config["inbounds"])[0])
	in["evil"] = "SECRET"
	object(in["tls"])["key"] = "SECRET"
	object(object(in["tls"])["reality"])["evil"] = "SECRET"
	h.db.Users["alice"].Credentials["reality"]["private_key"] = "SECRET"
	p, e := h.payload("alice")
	if e != nil {
		t.Fatal(e)
	}
	b, _ := json.Marshal(p)
	for _, secret := range []string{"SECRET", "private_key", "handshake", "@admin", "certificate"} {
		if strings.Contains(string(b), secret) {
			t.Fatalf("unsafe export: %s", secret)
		}
	}
	if p.SchemaVersion != 1 {
		t.Fatal("missing version")
	}
	uri, e := URI(p, p.Inbounds[0])
	if e != nil || !strings.Contains(uri, "security=reality") || !strings.Contains(uri, "pbk=") {
		t.Fatalf("URI %s: %v", uri, e)
	}
}

func TestDurableStatsResetsAndAdminExclusion(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	values := []int64{100, 150, 20, 80}
	idx := 0
	pid := "10"
	h.opts.Command = func(context.Context, string, ...string) ([]byte, error) { return []byte(pid), nil }
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		v := values[idx]
		idx++
		return []Stat{{"user>>>edge@alice>>>traffic>>>uplink", v}, {"user>>>edge@alice>>>traffic>>>downlink", v / 2}, {"user>>>edge@admin>>>traffic>>>uplink", 100000}}, nil
	}
	for i := 0; i < 3; i++ {
		if e := h.sample(context.Background()); e != nil {
			t.Fatal(e)
		}
	}
	if h.db.Users["alice"].Up != 170 || h.db.Users["alice"].Down != 85 {
		t.Fatalf("bad cumulative counts %+v", h.db.Users["alice"])
	}
	pid = "11"
	if e := h.sample(context.Background()); e != nil {
		t.Fatal(e)
	}
	if h.db.Users["alice"].Up != 250 {
		t.Fatal("runtime generation reset lost bytes")
	}
	if h.db.Users["admin"].Up != 0 || h.db.Users["admin"].Down != 0 {
		t.Fatal("admin accounted")
	}
	var db database
	if e := state.ReadJSON(h.opts.Config.UserDBPath, &db); e != nil {
		t.Fatal(e)
	}
	if db.Users["alice"].Up != 250 {
		t.Fatal("stats not durable")
	}
}

func TestFailClosedStats(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	stopped := false
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "systemctl" && args[0] == "stop" {
			stopped = true
		}
		return nil, nil
	}
	h.opts.Stats = func(context.Context, string) ([]Stat, error) { return nil, errors.New("unavailable") }
	var logs bytes.Buffer
	h.errOut = &logs
	if e := h.sample(context.Background()); e == nil {
		t.Fatal("failure ignored")
	}
	if !stopped || !h.db.StatsBlocked || h.active("alice", "edge") || !strings.Contains(logs.String(), "ERROR") {
		t.Fatal("not fail closed")
	}
	if !h.active("admin", "edge") {
		t.Fatal("admin assigned ordinary quota")
	}
}

func TestTransactionRollbackPreservesAccounting(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	saveHost(t, h)
	old, _ := os.ReadFile(h.opts.Config.ConfigPath)
	value := int64(50)
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		value += 10
		return []Stat{{"user>>>edge@alice>>>traffic>>>uplink", value}}, nil
	}
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "systemctl" && args[0] == "restart" {
			return nil, errors.New("injected restart failure")
		}
		return nil, nil
	}
	err := h.mutate(context.Background(), func() error { return h.addProtocol("trojan", "extra", 1443, "example.com", "") })
	if err == nil {
		t.Fatal("restart failure ignored")
	}
	now, _ := os.ReadFile(h.opts.Config.ConfigPath)
	if !bytes.Equal(old, now) {
		t.Fatal("rollback changed config")
	}
	if h.db.Users["alice"].Up != 70 {
		t.Fatalf("rollback lost final accounting: %d", h.db.Users["alice"].Up)
	}
	if !h.db.RuntimeStopped || !h.db.StatsBlocked {
		t.Fatal("uncertain runtime reopened")
	}
}

func TestValidationFailureDoesNotStopService(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "socks", "edge", 1080)
	saveHost(t, h)
	stopped := false
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "sing-box" {
			return nil, errors.New("invalid")
		}
		stopped = true
		return nil, nil
	}
	if e := h.mutate(context.Background(), func() error { return nil }); e == nil {
		t.Fatal("check failure ignored")
	}
	if stopped {
		t.Fatal("invalid candidate interrupted runtime")
	}
}

func TestCrashRecoveryJournal(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "socks", "edge", 1080)
	saveHost(t, h)
	j, e := h.snapshot()
	if e != nil {
		t.Fatal(e)
	}
	if e := state.WriteJSON(h.journalPath(), j); e != nil {
		t.Fatal(e)
	}
	if e := state.WriteJSON(h.opts.Config.ConfigPath, Object{"corrupted": true}); e != nil {
		t.Fatal(e)
	}
	if e := h.recover(context.Background()); e != nil {
		t.Fatal(e)
	}
	if e := h.load(); e != nil {
		t.Fatal(e)
	}
	if len(list(h.config["inbounds"])) != 1 || !h.db.RuntimeStopped || !h.db.StatsBlocked {
		t.Fatal("recovery did not restore safe state")
	}
}

func TestCentralGrantsAndPolicyLockout(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	h.central = centralState{InstanceID: "instance", ServerID: "server", AppliedRevision: 3}
	u := h.db.Users["alice"]
	u.Granted = true
	u.Period = 2
	u.Grant = 100
	u.QuotaBytes = 1000
	u.Up = 50
	u.Down = 50
	if h.active("alice", "edge") {
		t.Fatal("cumulative grant overspent")
	}
	u.Up = 49
	if !h.active("alice", "edge") {
		t.Fatal("remaining grant blocked")
	}
	u.Expires = h.opts.Now().Unix()
	if h.active("alice", "edge") {
		t.Fatal("expiration ignored")
	}
	h.db.Users["admin"].Grant = 0
	h.db.Users["admin"].QuotaBytes = 0
	if !h.active("admin", "edge") {
		t.Fatal("admin limited")
	}
	for _, response := range []SyncResponse{
		{Version: 1, Revision: 2, Users: []Policy{{Username: "admin"}}},
		{Version: 1, Revision: 4, Users: []Policy{{Username: "admin"}, {Username: "alice", Period: 1, QuotaBytes: 1000, GrantBytes: 100}}},
		{Version: 1, Revision: 4, Users: []Policy{{Username: "admin"}, {Username: "alice", Enabled: true, Period: 2, QuotaBytes: 1000, GrantBytes: 99}}},
	} {
		if e := h.validateResponse(response); e == nil {
			t.Fatal("stale policy accepted")
		}
	}
	saveHost(t, h)
	for _, args := range [][]string{{"user", "add", "--name", "mallory"}, {"user", "reset", "--name", "alice"}, {"config", "apply", "--file", "missing"}} {
		if e := h.run(context.Background(), args); e == nil || !strings.Contains(e.Error(), "central policy") {
			t.Fatalf("policy bypass: %v", e)
		}
	}
	if e := h.run(context.Background(), []string{"protocol", "add", "--type", "vmess-ws", "--tag", "new", "--port", "30001"}); e != nil {
		t.Fatal("local protocol change blocked", e)
	}
}

func TestEnrollmentLostResponseRetry(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "socks", "edge", 1080)
	saveHost(t, h)
	tokenPath := filepath.Join(filepath.Dir(h.opts.Config.UserDBPath), "token")
	if e := os.WriteFile(tokenPath, []byte("one-time-secret"), 0600); e != nil {
		t.Fatal(e)
	}
	var bodies [][]byte
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		bodies = append(bodies, b)
		var persisted centralState
		if e := state.ReadJSON(h.opts.Config.UserDBPath+".central", &persisted); e != nil || len(persisted.AgentToken) != 64 || persisted.EnrollmentToken != "one-time-secret" {
			t.Error("enrollment not persisted before request")
		}
		if len(bodies) == 1 {
			http.Error(w, "lost", 502)
			return
		}
		io.WriteString(w, `{"version":1,"server_id":"node"}`)
	}))
	defer server.Close()
	h.opts.HTTPClient = server.Client()
	if e := h.enroll(context.Background(), server.URL, tokenPath); e == nil {
		t.Fatal("expected first failure")
	}
	if e := os.Remove(tokenPath); e != nil {
		t.Fatal(e)
	}
	if e := h.enroll(context.Background(), server.URL, tokenPath); e != nil {
		t.Fatal(e)
	}
	if len(bodies) != 2 || !bytes.Equal(bodies[0], bodies[1]) {
		t.Fatal("enrollment retry changed identity")
	}
	if h.central.EnrollmentToken != "" {
		t.Fatal("spent enrollment token retained")
	}
}

func TestSyncRetryRolloverAndTombstones(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	h.central = centralState{URL: "", InstanceID: "instance", AgentToken: strings.Repeat("a", 64), ServerID: "node"}
	var bodies [][]byte
	round := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("a", 64) || r.Header.Get("X-Subflow-Server") != "node" {
			t.Error("missing central authentication")
		}
		b, _ := io.ReadAll(r.Body)
		bodies = append(bodies, b)
		var req SyncRequest
		json.Unmarshal(b, &req)
		round++
		if round == 1 {
			if len(req.Reports) != 0 {
				t.Error("first sync sent ungranted reports")
			}
			http.Error(w, "lost response", 503)
			return
		}
		response := SyncResponse{Version: 1, Revision: int64(round), Users: []Policy{{Username: "admin", Enabled: true, Nodes: []string{"*"}}, {Username: "alice", Enabled: true, QuotaBytes: 10000, GrantBytes: 1000, Period: 1, Nodes: []string{"edge"}}}}
		if round >= 3 {
			response.Users[1].Period = 2
		}
		if round >= 4 {
			response.Users = response.Users[:1]
		}
		json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()
	h.central.URL = server.URL
	h.opts.HTTPClient = server.Client()
	saveHost(t, h)
	if e := h.sync(context.Background()); e == nil {
		t.Fatal("first request should fail")
	}
	if e := h.sync(context.Background()); e != nil {
		t.Fatal(e)
	}
	if !bytes.Equal(bodies[0], bodies[1]) {
		t.Fatal("pending request not replayed exactly")
	}
	h.db.Users["alice"].Up = 80
	saveHost(t, h)
	if e := h.sync(context.Background()); e != nil {
		t.Fatal(e)
	}
	if h.db.Users["alice"].Period != 2 || h.db.Users["alice"].Up != 0 || len(h.db.Archive) != 1 || h.db.Archive[0].Up != 80 {
		t.Fatal("rollover lost old period")
	}
	h.db.Users["alice"].Up = 20
	saveHost(t, h)
	if e := h.sync(context.Background()); e != nil {
		t.Fatal(e)
	}
	if h.db.Users["alice"].Enabled || h.db.Users["alice"].Up != 20 {
		t.Fatal("revocation lost tombstone")
	}
	var last SyncRequest
	json.Unmarshal(bodies[len(bodies)-1], &last)
	if last.AppliedRevision != 3 {
		t.Fatal("applied revision advanced before successful apply")
	}
	found := false
	for _, r := range last.Reports {
		if r.Username == "admin" {
			t.Fatal("admin report")
		}
		if r.Period == 1 && r.Up == 80 {
			found = true
		}
	}
	if !found {
		t.Fatal("old period was not reported")
	}
}

func TestCentralRejectsRedirectAndOrigins(t *testing.T) {
	for _, raw := range []string{"http://example.com", "https://user:pass@example.com", "https://example.com/api", "https://example.com/?secret=1", "https://example.com/#x"} {
		if _, e := origin(raw); e == nil {
			t.Fatalf("unsafe origin %s", raw)
		}
	}
	h := testHost(t)
	called := false
	target := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { called = true }))
	defer target.Close()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 307) }))
	defer server.Close()
	h.opts.HTTPClient = server.Client()
	h.central.URL = server.URL
	var response SyncResponse
	if e := h.post(context.Background(), "/agent/sync", []byte("{}"), &response, false); e == nil || called {
		t.Fatal("redirect followed")
	}
}

func TestNativeHTTP2GRPCStats(t *testing.T) {
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	protocols := new(http.Protocols)
	protocols.SetUnencryptedHTTP2(true)
	server := &http.Server{Protocols: protocols, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 || r.URL.Path != "/v2ray.core.app.stats.command.StatsService/QueryStats" {
			t.Error("wrong RPC")
		}
		request, _ := io.ReadAll(r.Body)
		if !bytes.Equal(request[7:], []byte("user>>>")) {
			t.Error("wrong QueryStats pattern")
		}
		name := "user>>>edge@alice>>>traffic>>>uplink"
		stat := append([]byte{0x0a, byte(len(name))}, []byte(name)...)
		stat = append(stat, 0x10, 123)
		message := append([]byte{0x0a, byte(len(stat))}, stat...)
		frame := make([]byte, 5)
		binary.BigEndian.PutUint32(frame[1:], uint32(len(message)))
		frame = append(frame, message...)
		w.Header().Set("Content-Type", "application/grpc")
		w.Header().Set("Trailer", "Grpc-Status")
		w.Write(frame)
		w.Header().Set("Grpc-Status", "0")
	})}
	go server.Serve(listener)
	defer server.Close()
	stats, e := QueryStats(context.Background(), listener.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	if len(stats) != 1 || stats[0].Value != 123 {
		t.Fatalf("bad stats %v", stats)
	}
	if _, e := QueryStats(context.Background(), "192.0.2.1:10085"); e == nil {
		t.Fatal("nonlocal stats allowed")
	}
}

func TestOfficialSingboxConfigCompatibility(t *testing.T) {
	binary := os.Getenv("NODEHOST_TEST_SINGBOX")
	if binary == "" {
		t.Skip("set NODEHOST_TEST_SINGBOX to an official sing-box binary")
	}
	h := testHost(t)
	ordinary(h, "alice")
	for i, p := range Protocols {
		addNode(t, h, p, p, 20000+i)
	}
	// Official default releases omit with_v2ray_api. Check the complete
	// protocol/auth/routing schema separately; RPC itself is tested over h2c.
	delete(h.config, "experimental")
	path := h.opts.Config.ConfigPath
	if e := state.WriteJSON(path, h.config); e != nil {
		t.Fatal(e)
	}
	if b, e := exec.Command(binary, "check", "-c", path).CombinedOutput(); e != nil {
		t.Fatalf("official sing-box check: %v\n%s", e, b)
	}
	for _, u := range h.db.Users {
		u.Enabled = false
	}
	if e := h.render(); e != nil {
		t.Fatal(e)
	}
	delete(h.config, "experimental")
	if e := state.WriteJSON(path, h.config); e != nil {
		t.Fatal(e)
	}
	if b, e := exec.Command(binary, "check", "-c", path).CombinedOutput(); e != nil {
		t.Fatalf("all-disabled check: %v\n%s", e, b)
	}
}

func TestOfficialSOCKSAuthentication(t *testing.T) {
	binary := os.Getenv("NODEHOST_TEST_SINGBOX")
	if binary == "" {
		t.Skip("set NODEHOST_TEST_SINGBOX")
	}
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", port)
	admin := h.db.Users["admin"].Credentials["edge"]
	alice := h.db.Users["alice"].Credentials["edge"]
	echo, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer echo.Close()
	go func() {
		conn, e := echo.Accept()
		if e != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		b := make([]byte, 4)
		if _, e := io.ReadFull(conn, b); e == nil {
			conn.Write(b)
		}
	}()
	h.db.Users["alice"].Enabled = false
	if e := h.render(); e != nil {
		t.Fatal(e)
	}
	delete(h.config, "experimental")
	if e := state.WriteJSON(h.opts.Config.ConfigPath, h.config); e != nil {
		t.Fatal(e)
	}
	cmd := exec.Command(binary, "run", "-c", h.opts.Config.ConfigPath)
	if e := cmd.Start(); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	address := net.JoinHostPort("127.0.0.1", fmt.Sprint(port))
	deadline := time.Now().Add(5 * time.Second)
	for {
		conn, e := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if e == nil {
			conn.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("sing-box did not become ready")
		}
		time.Sleep(20 * time.Millisecond)
	}
	auth := func(credential Object) byte {
		t.Helper()
		conn, e := net.DialTimeout("tcp", address, time.Second)
		if e != nil {
			t.Fatal(e)
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(time.Second))
		conn.Write([]byte{5, 1, 2})
		reply := make([]byte, 2)
		if _, e := io.ReadFull(conn, reply); e != nil {
			t.Fatal(e)
		}
		if reply[1] != 2 {
			t.Fatal("SOCKS server did not require auth")
		}
		user, pass := text(credential["username"]), text(credential["password"])
		frame := append([]byte{1, byte(len(user))}, []byte(user)...)
		frame = append(frame, byte(len(pass)))
		frame = append(frame, []byte(pass)...)
		conn.Write(frame)
		if _, e := io.ReadFull(conn, reply); e != nil {
			t.Fatal(e)
		}
		if reply[1] == 0 && user == text(admin["username"]) {
			targetPort := echo.Addr().(*net.TCPAddr).Port
			conn.Write([]byte{5, 1, 0, 1, 127, 0, 0, 1, byte(targetPort >> 8), byte(targetPort)})
			connectReply := make([]byte, 10)
			if _, e := io.ReadFull(conn, connectReply); e != nil {
				t.Fatal("authorized route failed", e)
			}
			if connectReply[1] != 0 {
				t.Fatal("authorized direct route rejected")
			}
			conn.Write([]byte("ping"))
			echoed := make([]byte, 4)
			if _, e := io.ReadFull(conn, echoed); e != nil || string(echoed) != "ping" {
				t.Fatal("authorized route did not carry traffic", e)
			}
		}
		return reply[1]
	}
	if auth(admin) != 0 {
		t.Fatal("admin credential rejected")
	}
	if auth(alice) == 0 {
		t.Fatal("disabled SOCKS credential accepted")
	}
}

func TestChineseMenuAndHelp(t *testing.T) {
	h := testHost(t)
	var out bytes.Buffer
	h.out = &out
	if e := h.menu(context.Background(), strings.NewReader("0\n")); e != nil {
		t.Fatal(e)
	}
	for _, item := range []string{"协议", "用户", "状态", "中转", "WARP", "导出", "系统", "退出"} {
		if !strings.Contains(out.String(), item) {
			t.Fatalf("menu missing %s", item)
		}
	}
	if !strings.Contains(Help, "agent enroll") || !strings.Contains(Help, "quota-bytes") {
		t.Fatal("help incomplete")
	}
}

func TestProtocolUpdateLeavesOtherNodesAndCredentialsUntouched(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "vless-reality", "first", 20443)
	addNode(t, h, "trojan", "second", 21443)
	saveHost(t, h)
	second, _ := json.Marshal(list(h.config["inbounds"])[1])
	credentials, _ := json.Marshal(h.db.Users["alice"].Credentials)
	if e := h.run(context.Background(), []string{"protocol", "update", "--tag", "first", "--port", "22443", "--server-name", "new.example.com"}); e != nil {
		t.Fatal(e)
	}
	nowSecond, _ := json.Marshal(list(h.config["inbounds"])[1])
	nowCredentials, _ := json.Marshal(h.db.Users["alice"].Credentials)
	if !bytes.Equal(second, nowSecond) || !bytes.Equal(credentials, nowCredentials) {
		t.Fatal("update changed unrelated node or credentials")
	}
}

func TestQuotaApplyFailureStopsExistingPermissiveRuntime(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	h.db.Users["alice"].QuotaBytes = 100
	saveHost(t, h)
	stopped := false
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		return []Stat{{"user>>>edge@alice>>>traffic>>>uplink", 150}}, nil
	}
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "sing-box" {
			return nil, errors.New("check failure")
		}
		if len(args) > 0 && args[0] == "stop" {
			stopped = true
		}
		return nil, nil
	}
	if e := h.enforce(context.Background()); e == nil {
		t.Fatal("apply failure ignored")
	}
	if !stopped || !h.db.RuntimeStopped || h.active("alice", "edge") {
		t.Fatal("quota enforcement failed open")
	}
}

func TestQuarantinedPeriodDoesNotReopenAfterStatsRecovery(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	quarantine(&h.db, nil)
	h.db.RuntimeStopped = false
	h.db.StatsBlocked = true
	if e := h.sample(context.Background()); e != nil {
		t.Fatal(e)
	}
	if h.db.StatsBlocked || h.active("alice", "edge") {
		t.Fatal("restored API reopened uncertain period")
	}
	h.db.Users["alice"].Period++
	if !h.active("alice", "edge") {
		t.Fatal("new authorized period did not clear quarantine")
	}
}

func TestDurableResponseRetriesApplyWithoutAnotherRequest(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "socks", "edge", 1080)
	requests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		io.WriteString(w, `{"version":1,"revision":7,"users":[{"username":"admin","enabled":true,"nodes":["*"]},{"username":"alice","enabled":true,"quota_bytes":10000,"grant_bytes":1000,"period":1,"nodes":["edge"]}]}`)
	}))
	defer server.Close()
	h.central = centralState{URL: server.URL, InstanceID: "instance", ServerID: "server", AgentToken: strings.Repeat("a", 64)}
	h.opts.HTTPClient = server.Client()
	saveHost(t, h)
	fail := true
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "sing-box" && fail {
			return nil, errors.New("injected validation failure")
		}
		return nil, nil
	}
	if e := h.sync(context.Background()); e == nil {
		t.Fatal("expected failed apply")
	}
	var persisted centralState
	if e := state.ReadJSON(h.opts.Config.UserDBPath+".central", &persisted); e != nil {
		t.Fatal(e)
	}
	if persisted.Response == nil || persisted.AppliedRevision != 0 || len(persisted.Pending) == 0 {
		t.Fatal("response/applied revision not durable")
	}
	fail = false
	if e := h.sync(context.Background()); e != nil {
		t.Fatal(e)
	}
	if requests != 1 || h.central.AppliedRevision != 7 {
		t.Fatal("accepted request retransmitted or revision not applied")
	}
}

func TestStandaloneCLIAndRouting(t *testing.T) {
	h := testHost(t)
	run := func(args ...string) {
		t.Helper()
		if e := h.run(context.Background(), args); e != nil {
			t.Fatalf("%v: %v", args, e)
		}
	}
	run("init")
	run("protocol", "add", "--type", "socks", "--tag", "edge", "--port", "21080")
	run("user", "add", "--name", "alice", "--quota-bytes", "1000", "--expires", "1900000000")
	run("user", "update", "--name", "alice", "--nodes", "edge", "--enabled", "false")
	if h.active("alice", "edge") {
		t.Fatal("disabled standalone user active")
	}
	run("user", "update", "--name", "alice", "--enabled", "true")
	run("relay", "set", "--host", "127.0.0.1", "--port", "11080", "--full")
	run("warp", "set", "--host", "127.0.0.1", "--port", "40000")
	path := filepath.Join(filepath.Dir(h.opts.Config.MetaPath), "rules.json")
	if e := state.WriteJSON(path, Object{"version": 3, "rules": []any{Object{"domain_suffix": []any{"example.com"}}}}); e != nil {
		t.Fatal(e)
	}
	run("relay", "rule-add", "--tag", "domains", "--file", path, "--outbound", "warp")
	rules := list(object(h.config["route"])["rules"])
	if object(rules[0])["outbound"] != "warp" || object(rules[1])["outbound"] != "relay" {
		t.Fatal("rule-set/full-node routing missing")
	}
	for _, r := range rules[:len(rules)-1] {
		if len(list(object(r)["auth_user"])) == 0 || len(list(object(r)["inbound"])) == 0 {
			t.Fatal("route bypasses authorization")
		}
	}
	run("relay", "rule-delete", "--tag", "domains")
	run("warp", "off")
	run("relay", "off")
	run("user", "reset", "--name", "alice")
	if h.db.Users["alice"].Period != 1 {
		t.Fatal("standalone reset did not change period")
	}
	run("user", "delete", "--name", "alice")
	if h.db.Users["alice"].Enabled {
		t.Fatal("deletion still serves")
	}
	run("protocol", "delete", "--tag", "edge")
	if len(list(h.config["inbounds"])) != 0 {
		t.Fatal("protocol deletion failed")
	}
}

func TestAllNativeURIFormats(t *testing.T) {
	h := testHost(t)
	for i, p := range Protocols {
		addNode(t, h, p, p, 23000+i)
	}
	payload, e := h.payload("admin")
	if e != nil {
		t.Fatal(e)
	}
	if len(payload.Inbounds) != 8 {
		t.Fatal("missing protocol export")
	}
	for _, in := range payload.Inbounds {
		uri, e := URI(payload, in)
		if e != nil {
			t.Fatal(e)
		}
		if strings.Contains(uri, "private_key") || !strings.Contains(uri, "://") {
			t.Fatalf("invalid URI %s", uri)
		}
	}
	if payload.Usage["used_up_bytes"] != int64(0) || payload.Usage["quota_gb"] != float64(0) {
		t.Fatal("admin usage export not zero")
	}
}

func TestMalformedStatisticsAndSecretRedaction(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		return []Stat{{"user>>>edge@alice>>>traffic>>>uplink", -1}}, nil
	}
	if e := h.sample(context.Background()); e == nil || !h.db.RuntimeStopped {
		t.Fatal("malformed stats failed open")
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "SECRET_TOKEN", 401) }))
	defer server.Close()
	h.central.URL = server.URL
	h.opts.HTTPClient = server.Client()
	var response SyncResponse
	if e := h.post(context.Background(), "/agent/sync", []byte("{}"), &response, false); e == nil || strings.Contains(e.Error(), "SECRET_TOKEN") {
		t.Fatal("central error body leaked")
	}
}

func TestSlowCentralDoesNotBlockLocalAccountingOrProtocolChanges(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "socks", "edge", 1080)
	entered := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		<-release
		io.WriteString(w, `{"version":1,"revision":1,"users":[{"username":"admin","enabled":true,"nodes":["*"]}]}`)
	}))
	defer server.Close()
	h.opts.HTTPClient = server.Client()
	h.central = centralState{URL: server.URL, InstanceID: "id", AgentToken: strings.Repeat("a", 64), ServerID: "server"}
	saveHost(t, h)
	done := make(chan error, 1)
	go func() { done <- h.sync(context.Background()) }()
	<-entered
	local := newHost(h.opts, io.Discard, io.Discard)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := local.run(ctx, []string{"protocol", "add", "--type", "vmess-ws", "--tag", "next", "--port", "24443"})
	close(release)
	if e := <-done; e != nil {
		t.Fatal(e)
	}
	if err != nil {
		t.Fatal("central network blocked local configuration", err)
	}
	if e := h.load(); e != nil {
		t.Fatal(e)
	}
	if len(list(h.config["inbounds"])) != 2 {
		t.Fatal("sync overwrote local protocol change")
	}
}

func TestParentCentralWireSemantics(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	phase := 0
	lastSequence := int64(0)
	issuedRevision := int64(0)
	issuedPeriods := map[int64]bool{}
	previous := map[int64]Report{}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		phase++
		b, _ := io.ReadAll(r.Body)
		var raw map[string]json.RawMessage
		if e := json.Unmarshal(b, &raw); e != nil {
			t.Fatal(e)
		}
		for _, key := range []string{"version", "sequence", "applied_revision", "reports", "payloads", "inventory"} {
			if raw[key] == nil {
				t.Errorf("missing snake_case wire field %s", key)
			}
		}
		var request SyncRequest
		if e := json.Unmarshal(b, &request); e != nil {
			t.Fatal(e)
		}
		if request.Version != 1 || request.Sequence != lastSequence+1 || request.AppliedRevision > issuedRevision {
			t.Error("central sequence/applied revision violation")
		}
		lastSequence = request.Sequence
		if len(request.Reports) > 128 || len(request.Payloads) > 128 || len(request.Inventory) > 128 {
			t.Error("central collection limit violation")
		}
		if phase == 1 && len(request.Reports) != 0 {
			t.Error("first sync must report []")
		}
		for _, report := range request.Reports {
			if report.Username == "admin" || !issuedPeriods[report.Period] || report.Period < 1 {
				t.Error("admin or unissued-period report")
			}
			old := previous[report.Period]
			if report.Up < old.Up || report.Down < old.Down || report.Up > maxSafe || report.Down > maxSafe {
				t.Error("central counter constraint violated")
			}
			previous[report.Period] = report
		}
		for _, payload := range request.Payloads {
			if payload.SchemaVersion != 1 {
				t.Error("missing payload schema_version")
			}
		}
		period := int64(1)
		grant := int64(64 << 20)
		revision := int64(5)
		enabled := true
		if phase >= 2 {
			grant = 128 << 20
		}
		if phase >= 3 {
			period = 2
			grant = 64 << 20
			revision = 6
		}
		if phase >= 4 {
			enabled = false
		}
		response := SyncResponse{Version: 1, Revision: revision, Users: []Policy{
			{Username: "admin", Enabled: enabled, Period: 1, Nodes: []string{"*"}},
			{Username: "alice", Enabled: enabled, QuotaBytes: 1 << 30, Period: period, GrantBytes: grant, Nodes: []string{"edge"}},
		}}
		issuedPeriods[period] = true
		issuedRevision = revision
		json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()
	h.opts.HTTPClient = server.Client()
	h.central = centralState{URL: server.URL, InstanceID: "instance", ServerID: "node", AgentToken: strings.Repeat("a", 64)}
	saveHost(t, h)
	if e := h.sync(context.Background()); e != nil {
		t.Fatal(e)
	}
	if h.db.Users["alice"].Grant != 64<<20 {
		t.Fatal("initial 64MiB cumulative grant mismatch")
	}
	h.db.Users["alice"].Up = 20 << 20
	h.db.Users["alice"].Down = 16 << 20
	saveHost(t, h)
	if e := h.sync(context.Background()); e != nil {
		t.Fatal(e)
	}
	if previous[1].Up != 20<<20 || previous[1].Down != 16<<20 || h.db.Users["alice"].Grant != 128<<20 {
		t.Fatal("cumulative report/grant incorrectly treated as delta")
	}
	h.db.Users["alice"].Up = 22 << 20
	h.db.Users["alice"].Down = 19 << 20
	saveHost(t, h)
	if e := h.sync(context.Background()); e != nil {
		t.Fatal(e)
	}
	if h.db.Users["alice"].Period != 2 || h.db.Users["alice"].Up != 0 || h.db.Users["alice"].Down != 0 {
		t.Fatal("new-period counters not reset")
	}
	h.db.Users["alice"].Up = 123
	h.db.Users["alice"].Down = 456
	saveHost(t, h)
	if e := h.sync(context.Background()); e != nil {
		t.Fatal(e)
	}
	if previous[1].Up != 22<<20 || previous[1].Down != 19<<20 || previous[2].Up != 123 || previous[2].Down != 456 {
		t.Fatal("old-period history or new-period counters lost")
	}
	if h.db.Users["alice"].Enabled || h.db.Users["admin"].Enabled {
		t.Fatal("disabled server policy ignored")
	}
}

func TestCentralReportBatchingAndNumericBoundaries(t *testing.T) {
	reports := make([]Report, 300)
	for i := range reports {
		reports[i] = Report{Username: "alice", Period: int64(i + 1), Up: int64(i), Down: int64(i * 2)}
	}
	seen := map[int64]bool{}
	cursor := 0
	for i := 0; i < 3; i++ {
		var batch []Report
		batch, cursor = reportBatch(reports, cursor)
		if len(batch) != 128 {
			t.Fatal("wire report batch limit")
		}
		for _, r := range batch {
			seen[r.Period] = true
		}
	}
	if len(seen) != 300 {
		t.Fatal("old periods starved")
	}
	h := testHost(t)
	for _, p := range []Policy{
		{Username: "alice", Period: 0, QuotaBytes: 100, GrantBytes: 100},
		{Username: "alice", Period: 1, QuotaBytes: maxSafe + 1, GrantBytes: 100},
	} {
		if e := h.validateResponse(SyncResponse{Version: 1, Revision: 1, Users: []Policy{{Username: "admin"}, p}}); e == nil {
			t.Fatal("parent wire constraints not enforced")
		}
	}
}

func TestLifecycleCompatibilityAliases(t *testing.T) {
	h := testHost(t)
	for _, args := range [][]string{{"config", "init"}, {"maintenance"}, {"maintenance", "once"}, {"maintenance", "run"}} {
		if e := h.run(context.Background(), args); e != nil {
			t.Fatalf("%v: %v", args, e)
		}
	}
}

func TestCLIHelpTranscript(t *testing.T) {
	var output bytes.Buffer
	if e := RunWithOptions(context.Background(), []string{"help"}, nil, &output, io.Discard, Options{}); e != nil {
		t.Fatal(e)
	}
	t.Log("\n" + output.String())
}
