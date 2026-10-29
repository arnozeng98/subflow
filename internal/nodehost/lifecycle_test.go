package nodehost

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/arnozeng98/subflow/internal/state"
)

func TestMonthlyResetClampingAndTimezone(t *testing.T) {
	for _, test := range []struct {
		year      int
		month     time.Month
		day, want int
	}{
		{2024, time.February, 31, 29}, {2025, time.February, 31, 28}, {2025, time.April, 31, 30}, {2025, time.April, 32, 30}, {2025, time.January, 32, 31}, {2025, time.January, 1, 1},
	} {
		if got := resetDate(test.year, test.month, test.day, time.UTC).Day(); got != test.want {
			t.Fatalf("reset day %d got %d want %d", test.day, got, test.want)
		}
	}
	h := testHost(t)
	h.opts.Config.BusinessTimezone = "Asia/Shanghai"
	now := time.Date(2026, time.March, 31, 16, 0, 0, 0, time.UTC)
	h.opts.Now = func() time.Time { return now }
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	u := h.db.Users["alice"]
	u.ResetDay = 1
	u.ResetAnchor = time.Date(2026, time.February, 2, 0, 0, 0, 0, time.UTC).Unix()
	u.Up = 900
	u.Down = 100
	u.Manual = 20
	credentials, _ := json.Marshal(u.Credentials)
	saveHost(t, h)
	if err := h.enforce(context.Background()); err != nil {
		t.Fatal(err)
	}
	u = h.db.Users["alice"]
	after, _ := json.Marshal(u.Credentials)
	if u.Up != 0 || u.Down != 0 || u.Manual != 0 || u.Period != 1 || u.LastReset != "2026-04-01" || u.ResetAnchor != now.Unix() || !bytes.Equal(credentials, after) {
		t.Fatalf("timezone/missed reset failed %+v", u)
	}
	if err := h.enforce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if h.db.Users["alice"].Period != 1 {
		t.Fatal("same schedule applied twice")
	}
}

func TestManualAndManagedResetPolicies(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	h.db.Users["alice"].Up = 100
	h.db.Users["alice"].ResetDay = 0
	h.db.Users["admin"].ResetDay = 32
	saveHost(t, h)
	if err := h.enforce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if h.db.Users["alice"].Up != 100 || h.db.Users["admin"].ResetDay != 0 {
		t.Fatal("manual/admin reset policy violated")
	}
	h.central = centralState{InstanceID: "instance", ServerID: "server"}
	u := h.db.Users["alice"]
	u.ResetDay = 32
	u.ResetAnchor = 1
	u.Period = 1
	u.Granted = true
	u.Grant = 1000
	u.QuotaBytes = 1000
	saveHost(t, h)
	if err := h.enforce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if h.db.Users["alice"].Up != 100 || h.db.Users["alice"].Period != 1 {
		t.Fatal("local calendar overrode central period")
	}
	for _, action := range []string{"renew", "correct", "reset"} {
		if err := h.run(context.Background(), []string{"user", action, "--name", "alice"}); err == nil || !strings.Contains(err.Error(), "central policy") {
			t.Fatal("managed user edit allowed", action, err)
		}
	}
}

func TestMissedMonthEndAndDisabledUser(t *testing.T) {
	h := testHost(t)
	h.opts.Config.BusinessTimezone = "UTC"
	h.opts.Now = func() time.Time { return time.Date(2026, time.June, 20, 12, 0, 0, 0, time.UTC) }
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	u := h.db.Users["alice"]
	u.Enabled = false
	u.ResetDay = 32
	u.ResetAnchor = time.Date(2026, time.January, 31, 0, 0, 0, 0, time.UTC).Unix()
	u.Up = 500
	saveHost(t, h)
	if err := h.enforce(context.Background()); err != nil {
		t.Fatal(err)
	}
	u = h.db.Users["alice"]
	if u.LastReset != "2026-05-31" || u.Up != 0 || u.Enabled || u.Period != 1 {
		t.Fatalf("missed month-end failed %+v", u)
	}
	next, err := h.nextReset(u)
	if err != nil || next != time.Date(2026, time.June, 30, 0, 0, 0, 0, time.UTC).Unix() {
		t.Fatal("next month-end wrong", next, err)
	}
}

func TestRenewCorrectResetKeepCredentials(t *testing.T) {
	h := testHost(t)
	h.opts.Config.BusinessTimezone = "America/New_York"
	location, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, time.March, 7, 12, 0, 0, 0, location)
	h.opts.Now = func() time.Time { return now }
	addNode(t, h, "socks", "edge", 1080)
	saveHost(t, h)
	run := func(args ...string) {
		t.Helper()
		if err := h.run(context.Background(), args); err != nil {
			t.Fatalf("%v: %v", args, err)
		}
	}
	run("user", "add", "--name", "alice", "--quota-bytes", "1000", "--reset-day", "32")
	before, _ := json.Marshal(h.db.Users["alice"].Credentials)
	h.db.Users["alice"].Up = 200
	h.db.Users["alice"].Down = 100
	saveHost(t, h)
	run("user", "renew", "--name", "alice", "--days", "2")
	u := h.db.Users["alice"]
	want := time.Date(2026, time.March, 9, 12, 0, 0, 0, location).Unix()
	if u.Expires != want || u.Up != 200 || u.Down != 100 || !u.Enabled {
		t.Fatal("calendar-day renewal failed")
	}
	run("user", "correct", "--name", "alice", "--up-bytes", "20", "--down-bytes", "10")
	if h.db.Users["alice"].Up != 20 || h.db.Users["alice"].Down != 10 || h.db.Users["alice"].Manual != 0 {
		t.Fatal("usage correction failed")
	}
	run("user", "usage", "--name", "alice")
	run("user", "renew", "--name", "alice", "--days", "3", "--reset-usage")
	if h.db.Users["alice"].Up != 0 || h.db.Users["alice"].Down != 0 || h.db.Users["alice"].Manual != 0 {
		t.Fatal("renewal reset failed")
	}
	run("user", "reset", "--name", "alice", "--reset-day", "0")
	after, _ := json.Marshal(h.db.Users["alice"].Credentials)
	if !bytes.Equal(before, after) || h.db.Users["alice"].ResetDay != 0 {
		t.Fatal("credentials rotated or manual schedule failed")
	}
}

func TestNativeACMEVersionSelectionAndSecretProjection(t *testing.T) {
	for _, version := range []string{"1.13.0", "1.14.0", "1.16.0"} {
		t.Run(version, func(t *testing.T) {
			h := testHost(t)
			addNode(t, h, "trojan", "edge", 443)
			saveHost(t, h)
			credentials, _ := json.Marshal(h.db.Users["admin"].Credentials)
			h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
				if name == "sing-box" && len(args) > 0 && args[0] == "version" {
					return []byte("sing-box version " + version), nil
				}
				return nil, nil
			}
			tokenPath := filepath.Join(filepath.Dir(h.opts.Config.MetaPath), "cloudflare-token")
			if err := os.WriteFile(tokenPath, []byte("CLOUDFLARE_SECRET_TOKEN"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := h.run(context.Background(), []string{"protocol", "acme", "--tag", "edge", "--domain", "node.example.com", "--email", "admin@example.com", "--token-file", tokenPath}); err != nil {
				t.Fatal(err)
			}
			config := object(object(list(h.config["inbounds"])[0])["tls"])
			key := "certificate_provider"
			if version == "1.13.0" {
				key = "acme"
			}
			acme := object(config[key])
			if text(object(acme["dns01_challenge"])["api_token"]) != "CLOUDFLARE_SECRET_TOKEN" || acme["disable_http_challenge"] != true || acme["disable_tls_alpn_challenge"] != true {
				t.Fatal("DNS-01 config missing")
			}
			if config["certificate"] != nil || config["key"] != nil {
				t.Fatal("self-signed material still overrides ACME")
			}
			if key == "certificate_provider" && acme["type"] != "acme" {
				t.Fatal("native provider type missing")
			}
			info, err := os.Stat(h.opts.Config.ConfigPath)
			if err != nil {
				t.Fatal(err)
			}
			if info.Mode().Perm() != 0600 {
				probe, probeErr := os.Stat(tokenPath)
				if probeErr != nil || probe.Mode().Perm() == 0600 {
					t.Fatal("Cloudflare token config is not protected")
				}
				t.Log("host filesystem does not expose POSIX mode 0600 (WSL/NTFS); state.WriteJSON requests 0600")
			}
			payload, err := h.payload("admin")
			if err != nil {
				t.Fatal(err)
			}
			raw, _ := json.Marshal(payload)
			if strings.Contains(string(raw), "CLOUDFLARE") || strings.Contains(string(raw), "api_token") || strings.Contains(string(raw), "acme") {
				t.Fatal("ACME token/settings leaked")
			}
			after, _ := json.Marshal(h.db.Users["admin"].Credentials)
			if !bytes.Equal(credentials, after) {
				t.Fatal("ACME rotated protocol credentials")
			}
			if err := h.run(context.Background(), []string{"protocol", "update", "--tag", "edge", "--server-name", "other.example.com"}); err == nil {
				t.Fatal("production TLS silently downgraded to self-signed")
			}
		})
	}
}

func TestManualCertificateImportAndValidation(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "anytls", "edge", 443)
	saveHost(t, h)
	cert, err := certificate("production.example.com", h.opts.Now())
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Dir(h.opts.Config.MetaPath)
	certPath := filepath.Join(dir, "issued.pem")
	keyPath := filepath.Join(dir, "issued.key")
	if err := os.WriteFile(certPath, []byte(text(list(cert["certificate"])[0])), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, []byte(text(list(cert["key"])[0])), 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"protocol", "certificate-import", "--tag", "edge", "--server-name", "production.example.com", "--cert-file", certPath, "--key-file", keyPath}
	if err := h.run(context.Background(), args); err != nil {
		t.Fatal(err)
	}
	if h.meta["edge"].TLSMode != "imported" {
		t.Fatal("import mode not recorded")
	}
	before, _ := os.ReadFile(h.opts.Config.ConfigPath)
	wrong, err := certificate("other.example.com", h.opts.Now())
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(keyPath, []byte(text(list(wrong["key"])[0])), 0600)
	if err := h.run(context.Background(), args); err == nil {
		t.Fatal("mismatched key accepted")
	}
	after, _ := os.ReadFile(h.opts.Config.ConfigPath)
	if !bytes.Equal(before, after) {
		t.Fatal("invalid certificate modified live config")
	}
}

func TestPreparedRestartHoldAndReliableStartupProbe(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	h.central = centralState{InstanceID: "instance", ServerID: "server"}
	u := h.db.Users["alice"]
	u.Granted = true
	u.Period = 1
	u.Grant = 1000
	u.QuotaBytes = 1000
	counter := int64(37)
	restarts := 0
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		return []Stat{{"user>>>edge@alice>>>traffic>>>uplink", counter}}, nil
	}
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "systemctl" && len(args) > 0 && args[0] == "restart" {
			restarts++
			counter = 0
		}
		return nil, nil
	}
	saveHost(t, h)
	if err := h.run(context.Background(), []string{"service", "prepare-restart"}); err != nil {
		t.Fatal(err)
	}
	if !h.db.RestartPrepared || !h.db.RuntimeStopped || h.db.Users["alice"].Up != 37 {
		t.Fatal("prepare hook lost accounting or did not hold")
	}
	if err := h.enforce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := h.bootstrap(context.Background()); err != nil {
		t.Fatal(err)
	}
	if restarts != 0 {
		t.Fatal("agent restarted held core")
	}
	if err := h.sync(context.Background()); !errors.Is(err, ErrRestartPrepared) {
		t.Fatal("sync bypassed upgrade hold", err)
	}
	if err := h.run(context.Background(), []string{"system", "start"}); err != nil {
		t.Fatal(err)
	}
	if h.db.RestartPrepared || h.db.ProbeRequired || !h.active("alice", "edge") {
		t.Fatal("system start did not complete its restricted-runtime probe")
	}
	if err := h.enforce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if h.db.ProbeRequired || !h.active("alice", "edge") || h.db.Users["alice"].Up != 37 {
		t.Fatal("probe did not restore only reliable remaining grant")
	}
}

func TestAgentBootstrapAccountsAndStartsRestricted(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	h.central = centralState{InstanceID: "instance", ServerID: "server"}
	u := h.db.Users["alice"]
	u.Period = 1
	u.Grant = 1000
	u.QuotaBytes = 1000
	u.Granted = false
	counter := int64(50)
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		return []Stat{{"user>>>edge@alice>>>traffic>>>uplink", counter}}, nil
	}
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "systemctl" && len(args) > 0 && args[0] == "restart" {
			var config Object
			if err := state.ReadJSON(h.opts.Config.ConfigPath, &config); err != nil {
				t.Error(err)
			}
			for _, user := range list(object(list(config["inbounds"])[0])["users"]) {
				if text(object(user)["username"]) == "edge@alice" {
					t.Error("unproven grant served during bootstrap")
				}
			}
			counter = 0
		}
		return nil, nil
	}
	saveHost(t, h)
	if err := h.bootstrap(context.Background()); err != nil {
		t.Fatal(err)
	}
	if h.db.Users["alice"].Up != 50 || !h.db.ProbeRequired {
		t.Fatal("bootstrap discarded existing counters")
	}
	if err := h.enforce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if h.active("alice", "edge") {
		t.Fatal("unissued grant became spendable after probe")
	}
}
