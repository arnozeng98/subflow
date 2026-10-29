package deploy

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/arnozeng98/subflow/internal/settings"
)

func testDirectory(t *testing.T) string {
	t.Helper()
	return t.TempDir()
}

func testApp(t *testing.T) *app {
	t.Helper()
	return &app{o: Options{RootDir: testDirectory(t), Arch: "amd64", HTTPClient: defaultHTTPClient(), Execute: func(_ context.Context, c Command) ([]byte, error) {
		if len(c.Args) > 0 {
			switch c.Args[0] {
			case "is-active":
				return []byte("inactive"), errors.New("inactive")
			case "is-enabled":
				return []byte("disabled"), errors.New("disabled")
			}
		}
		return nil, nil
	}}, out: io.Discard, errOut: io.Discard}
}

func writeTest(t *testing.T, p string, b []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, b, 0600); err != nil {
		t.Fatal(err)
	}
}

func archiveFixture(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	tw := tar.NewWriter(gz)
	for _, name := range sortedKeys(files) {
		data := files[name]
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0755, Size: int64(len(data)), Typeflag: tar.TypeReg}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestChecksumsFailClosed(t *testing.T) {
	sum := sha256.Sum256([]byte("binary"))
	good := hex.EncodeToString(sum[:])
	for _, test := range []struct {
		name, manifest string
		ok             bool
	}{
		{"valid", good + "  binary.tar.gz\n", true},
		{"binary-marker", good + " *binary.tar.gz\n", true},
		{"missing", good + " other.tar.gz\n", false},
		{"duplicate", good + " binary.tar.gz\n" + good + " binary.tar.gz\n", false},
		{"invalid", "123 binary.tar.gz\n", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			b, err := checksum([]byte(test.manifest), "binary.tar.gz")
			if (err == nil) != test.ok {
				t.Fatalf("checksum result %x, %v", b, err)
			}
		})
	}
}

func TestArchiveRejectsTraversalAndLinks(t *testing.T) {
	for _, name := range []string{"../subflow", "/subflow", "cloudflare/../../etc/passwd", "cloudflare\\bad", "C:/subflow"} {
		t.Run(name, func(t *testing.T) {
			if _, err := extractArchive(archiveFixture(t, map[string][]byte{name: []byte("bad")})); err == nil {
				t.Fatal("unsafe path accepted")
			}
		})
	}
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	tw := tar.NewWriter(gz)
	_ = tw.WriteHeader(&tar.Header{Name: "cloudflare/link", Linkname: "/etc", Typeflag: tar.TypeSymlink})
	_ = tw.Close()
	_ = gz.Close()
	if _, err := extractArchive(b.Bytes()); err == nil {
		t.Fatal("symlink accepted")
	}
	valid := archiveFixture(t, map[string][]byte{"subflow": []byte("native"), "cloudflare/functions/user.ts": []byte("source")})
	files, err := extractArchive(valid)
	if err != nil || string(files["subflow"]) != "native" {
		t.Fatalf("valid archive: %v", err)
	}
}

func TestReleaseNamespacesAndChecksum(t *testing.T) {
	body := archiveFixture(t, map[string][]byte{"sing-box": []byte("native")})
	sum := sha256.Sum256(body)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/releases":
			io.WriteString(w, `[{"tag_name":"subflow-v2","assets":[{"name":"subflow-linux-amd64.tar.gz"}]},{"tag_name":"v1.12.0","assets":[{"name":"sing-box-linux-amd64.tar.gz"}]}]`)
		case "/releases/latest":
			io.WriteString(w, `{"tag_name":"subflow-v2","assets":[{"name":"subflow-linux-amd64.tar.gz"}]}`)
		case "/download/v1.12.0/sha256sum.txt":
			fmt.Fprintf(w, "%x  sing-box-linux-amd64.tar.gz\n", sum)
		case "/download/v1.12.0/sing-box-linux-amd64.tar.gz":
			w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	a := testApp(t)
	a.o.ReleaseAPI = server.URL + "/releases"
	a.o.ReleaseBase = server.URL + "/download"
	tag, err := a.latestTag(context.Background(), "sing-box")
	if err != nil || tag != "v1.12.0" {
		t.Fatalf("kernel tag %q %v", tag, err)
	}
	tag, err = a.latestTag(context.Background(), "subflow")
	if err != nil || tag != "subflow-v2" {
		t.Fatalf("application tag %q %v", tag, err)
	}
	files, tag, err := a.release(context.Background(), "sing-box", "latest")
	if err != nil || tag != "v1.12.0" || string(files["sing-box"]) != "native" {
		t.Fatalf("release: %q %v", tag, err)
	}
	if _, _, err = a.release(context.Background(), "subflow", "v1.12.0"); err == nil {
		t.Fatal("kernel tag accepted as application")
	}
}

func TestTransactionRestoresConfigurationAndBinary(t *testing.T) {
	a := testApp(t)
	binary := a.path(binaryPath)
	config := a.path(envPath)
	users := a.path("/etc/sing-box-manager/user-manager.json")
	writeTest(t, binary, []byte("old binary"))
	writeTest(t, config, []byte("old config"))
	writeTest(t, users, []byte("untouched"))
	sentinel := errors.New("restart failed")
	err := a.transaction(context.Background(), func(tx *transaction) error {
		if err := tx.write(binary, []byte("new binary"), 0755); err != nil {
			return err
		}
		if err := tx.write(config, []byte("new config"), 0600); err != nil {
			return err
		}
		if err := tx.write(a.path(unitDir+"new.service"), []byte("new unit"), 0644); err != nil {
			return err
		}
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("missing primary error: %v", err)
	}
	for p, want := range map[string]string{binary: "old binary", config: "old config", users: "untouched"} {
		got, err := os.ReadFile(p)
		if err != nil || string(got) != want {
			t.Fatalf("%s: %q %v", p, got, err)
		}
	}
	if fileExists(a.path(unitDir + "new.service")) {
		t.Fatal("new file not rolled back")
	}
	matches, _ := filepath.Glob(binary + ".subflow-backup-*")
	if len(matches) != 0 {
		t.Fatal("successful rollback leaked backups")
	}
}

func TestRollbackStopsCandidateBeforeDeletingUnit(t *testing.T) {
	a := testApp(t)
	name := "subflow.service"
	var calls []string
	a.o.Execute = func(_ context.Context, c Command) ([]byte, error) {
		calls = append(calls, strings.Join(c.Args, " "))
		if len(c.Args) > 0 && c.Args[0] == "stop" && !fileExists(a.path(unitDir+name)) {
			t.Error("unit removed before process stopped")
		}
		return nil, nil
	}
	err := a.transaction(context.Background(), func(tx *transaction) error {
		tx.services = append(tx.services, savedService{name: name})
		if err := tx.write(a.path(unitDir+name), []byte("new"), 0644); err != nil {
			return err
		}
		return errors.New("failed")
	})
	if err == nil {
		t.Fatal("expected failure")
	}
	if len(calls) < 3 || calls[0] != "stop subflow.service" || calls[1] != "disable subflow.service" {
		t.Fatalf("recovery calls: %v", calls)
	}
}

func TestEnvironmentPreservesUnknownValuesAndToken(t *testing.T) {
	a := testApp(t)
	writeTest(t, a.path(envPath), []byte("SUBFLOW_API_TOKEN='exact-token'\nUNRELATED_SETTING='keep me'\nSUBFLOW_LISTEN_PORT=28081\n"))
	env, err := a.configuration(arguments{yes: true, sets: assignments{"SUBFLOW_PUBLIC_IP=example.com"}}, true)
	if err != nil {
		t.Fatal(err)
	}
	if env["SUBFLOW_API_TOKEN"] != "exact-token" || env["UNRELATED_SETTING"] != "keep me" {
		t.Fatalf("data lost: %v", env)
	}
	parsed, err := settings.ReadEnv(bytes.NewReader(encodeEnvironment(env)))
	if err != nil {
		t.Fatal(err)
	}
	if parsed["UNRELATED_SETTING"] != "keep me" {
		t.Fatal("literal env roundtrip failed")
	}
	if _, err = a.configuration(arguments{yes: true, sets: assignments{"SUBFLOW_LISTEN_PORT=99999"}}, false); err == nil {
		t.Fatal("invalid port accepted")
	}
	if _, err = a.configuration(arguments{yes: true, sets: assignments{"SUBFLOW_PUBLIC_IP=x\nINJECT=y"}}, false); err == nil {
		t.Fatal("newline accepted")
	}
}

func TestDryRunHasNoFilesystemNetworkOrProcessSideEffects(t *testing.T) {
	root := filepath.Join(testDirectory(t), "absent")
	var output bytes.Buffer
	err := RunWithOptions(context.Background(), []string{"--dry-run", "install", "--yes"}, nil, &output, io.Discard, Options{
		RootDir: root, Executable: "does-not-exist",
		Execute: func(context.Context, Command) ([]byte, error) { t.Fatal("process executed"); return nil, nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	if fileExists(root) {
		t.Fatal("dry-run wrote files")
	}
	if !strings.Contains(output.String(), "verify downloads") {
		t.Fatal(output.String())
	}
}

func TestManagedUnitsUseNativeCommands(t *testing.T) {
	u := units()
	for name, b := range u {
		text := string(b)
		for _, forbidden := range []string{"python", "bash", "sb.sh", " -c '"} {
			if strings.Contains(text, forbidden) {
				t.Fatalf("%s contains %s", name, forbidden)
			}
		}
	}
	if !strings.Contains(string(u["subflow-sync.timer"]), "OnUnitActiveSec=3min") {
		t.Fatal("wrong periodic schedule")
	}
	if !strings.Contains(string(u["subflow-maintenance.timer"]), "04:47:00") {
		t.Fatal("wrong daily schedule")
	}
	if !strings.Contains(string(u["subflow-agent.service"]), "subflow agent run") {
		t.Fatal("central agent service is missing")
	}
	for _, directive := range []string{"TimeoutStopSec=45", "ExecStopPost=/bin/systemctl stop sing-box.service"} {
		if !strings.Contains(string(u["subflow-agent.service"]), directive) {
			t.Fatalf("central agent missing fail-closed directive %s", directive)
		}
	}
}

func TestCronMigrationOnlyOwnedCommands(t *testing.T) {
	for _, line := range []string{"*/3 * * * * bash /root/sb.sh --periodic-sync >/dev/null 2>&1", "47 4 * * * /bin/bash /root/sb.sh --daily-maintenance", "@reboot /root/sing-box.sh --user-watch"} {
		if !legacyCron(line) {
			t.Fatalf("not recognized: %s", line)
		}
	}
	for _, line := range []string{"* * * * * echo /root/sb.sh --periodic-sync", "# * * * * * bash /root/sb.sh --periodic-sync", "* * * * * bash /home/user/sb.sh --periodic-sync", "* * * * * bash /root/sb.sh --custom"} {
		if legacyCron(line) {
			t.Fatalf("unrelated cron matched: %s", line)
		}
	}
}

func TestLogRetention(t *testing.T) {
	p := filepath.Join(testDirectory(t), "access.log")
	writeTest(t, p, []byte("0123456789"))
	if err := MaintainLogs(p, 4); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(p)
	if err != nil || string(got) != "6789" {
		t.Fatalf("retained %q %v", got, err)
	}
	if err := MaintainLogs(p, 0); err == nil {
		t.Fatal("zero retention accepted")
	}
}

func TestKernelRejectsMissingV2RayTagBeforeReplacement(t *testing.T) {
	data := archiveFixture(t, map[string][]byte{"sing-box": []byte("candidate")})
	sum := sha256.Sum256(data)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "sha256sum.txt") {
			fmt.Fprintf(w, "%x sing-box-linux-amd64.tar.gz\n", sum)
		} else {
			w.Write(data)
		}
	}))
	defer server.Close()
	a := testApp(t)
	a.o.ReleaseBase = server.URL
	old := a.path(kernelPath)
	writeTest(t, old, []byte("old"))
	a.o.Execute = func(_ context.Context, c Command) ([]byte, error) {
		if c.Name != "systemctl" {
			return []byte("sing-box version 1.0; tags: with_quic"), nil
		}
		if c.Args[0] == "is-active" {
			return []byte("inactive"), errors.New("inactive")
		}
		if c.Args[0] == "is-enabled" {
			return []byte("disabled"), errors.New("disabled")
		}
		return nil, nil
	}
	if err := a.installKernel(context.Background(), "v1.0"); err == nil || !strings.Contains(err.Error(), "with_v2ray_api") {
		t.Fatalf("expected tag rejection: %v", err)
	}
	got, _ := os.ReadFile(old)
	if string(got) != "old" {
		t.Fatal("old kernel was changed")
	}
}

func TestCloudflareRejectsInactiveTokenWithoutMutation(t *testing.T) {
	var methods []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method)
		io.WriteString(w, `{"success":true,"result":{"id":"token","status":"expired"}}`)
	}))
	defer server.Close()
	a := testApp(t)
	a.o.CloudflareAPI = server.URL
	_, err := (cfClient{a: a, token: "secret"}).permissions(context.Background(), arguments{account: strings.Repeat("a", 32), zone: "example.com"})
	if err == nil || !strings.Contains(err.Error(), "not active") {
		t.Fatalf("expected token error: %v", err)
	}
	if strings.Join(methods, ",") != "GET" {
		t.Fatalf("unexpected mutations %v", methods)
	}
}

func TestCloudflareErrorsDoNotExposeCredentials(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		io.WriteString(w, `{"success":false,"errors":[{"code":10000,"message":"secret-token"}]}`)
	}))
	defer server.Close()
	a := testApp(t)
	a.o.CloudflareAPI = server.URL
	err := (cfClient{a: a, token: "secret-token"}).request(context.Background(), "GET", "/test", nil, nil)
	if err == nil || strings.Contains(err.Error(), "secret-token") {
		t.Fatalf("unsafe error: %v", err)
	}
}

func TestTunnelConfigurationPreservesOtherIngress(t *testing.T) {
	var updated map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			io.WriteString(w, `{"success":true,"result":{"config":{"originRequest":{"connectTimeout":30},"ingress":[{"hostname":"keep.example.com","service":"http://127.0.0.1:80"},{"hostname":"api.example.com","service":"http://old"},{"service":"http_status:404"}]}}}`)
			return
		}
		if err := json.NewDecoder(r.Body).Decode(&updated); err != nil {
			t.Error(err)
		}
		io.WriteString(w, `{"success":true,"result":{}}`)
	}))
	defer server.Close()
	a := testApp(t)
	a.o.CloudflareAPI = server.URL
	tx := &transaction{a: a}
	err := (cfClient{a: a, token: "secret"}).configureTunnel(context.Background(), tx, "/accounts/account", "tunnel", "api.example.com", "http://127.0.0.1:28080")
	if err != nil {
		t.Fatal(err)
	}
	cfg := nestedMap(updated, "config")
	entries := cfg["ingress"].([]any)
	if len(entries) != 3 || entries[0].(map[string]any)["hostname"] != "keep.example.com" {
		t.Fatalf("ingress lost: %v", entries)
	}
	if cfg["originRequest"] == nil {
		t.Fatal("origin settings lost")
	}
	if entries[1].(map[string]any)["service"] != "http://127.0.0.1:28080" {
		t.Fatal("API route not replaced")
	}
	if len(tx.undos) != 1 {
		t.Fatal("no rollback registered")
	}
}

func TestDNSRefusesAmbiguousRecords(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			t.Error("mutated ambiguous DNS")
		}
		io.WriteString(w, `{"success":true,"result":[{"id":"a","type":"A"},{"id":"b","type":"AAAA"}]}`)
	}))
	defer server.Close()
	a := testApp(t)
	a.o.CloudflareAPI = server.URL
	err := (cfClient{a: a, token: "secret"}).ensureDNS(context.Background(), &transaction{a: a}, "zone", "api.example.com", "tunnel.cfargotunnel.com")
	if err == nil {
		t.Fatal("ambiguous records accepted")
	}
}

func TestCloudflareBuildEnvironmentDropsLegacyCredentials(t *testing.T) {
	t.Setenv("CLOUDFLARE_API_KEY", "legacy")
	t.Setenv("CLOUDFLARE_EMAIL", "legacy@example.com")
	t.Setenv("CF_API_TOKEN", "legacy")
	env := cleanCloudflareEnv("new", "account", "work")
	for _, entry := range env {
		if strings.Contains(entry, "legacy") {
			t.Fatalf("leaked legacy credential %s", entry)
		}
	}
	if !strings.Contains(strings.Join(env, "\n"), "CLOUDFLARE_API_TOKEN=new") {
		t.Fatal("missing token")
	}
}

func TestKernelUnknownCommandCannotEditAPIConfig(t *testing.T) {
	err := RunWithOptions(context.Background(), []string{"kernel", "edit", "--dry-run"}, nil, io.Discard, io.Discard, Options{RootDir: testDirectory(t)})
	if err == nil {
		t.Fatal("kernel edit routed to API edit")
	}
}

func fixtureAssets(t *testing.T, root string) {
	t.Helper()
	for p, b := range map[string]string{
		"package.json":                 `{"devDependencies":{"wrangler":"4.154.0"}}`,
		"package-lock.json":            `{"lockfileVersion":3}`,
		"tsconfig.json":                `{}`,
		"cloudflare/build.ts":          "// build",
		"cloudflare/functions/user.ts": "// gateway",
	} {
		writeTest(t, filepath.Join(root, filepath.FromSlash(p)), []byte(b))
	}
}

func fakeSystem(t *testing.T, a *app, active map[string]bool, failRestart *bool) {
	t.Helper()
	a.o.CheckAPI = func(context.Context, string, string) error { return nil }
	a.o.Execute = func(_ context.Context, c Command) ([]byte, error) {
		if c.Name == "crontab" {
			return []byte("no crontab for root"), errors.New("exit 1")
		}
		if n := len(c.Args); n >= 3 && c.Args[n-3] == "manager" && c.Args[n-2] == "system" {
			switch c.Args[n-1] {
			case "prepare-restart", "stop":
				active["sing-box.service"] = false
			case "start", "restart":
				if failRestart != nil && *failRestart {
					*failRestart = false
					return nil, errors.New("simulated restart failure")
				}
				active["sing-box.service"] = true
			}
			return nil, nil
		}
		if c.Name != "systemctl" {
			return []byte("sing-box version 1.0 tags: with_v2ray_api"), nil
		}
		op := c.Args[0]
		name := c.Args[len(c.Args)-1]
		switch op {
		case "is-active":
			if active[name] {
				return []byte("active"), nil
			}
			return []byte("inactive"), errors.New("inactive")
		case "is-enabled":
			if active[name] {
				return []byte("enabled"), nil
			}
			return []byte("disabled"), errors.New("disabled")
		case "restart":
			if failRestart != nil && *failRestart {
				*failRestart = false
				return nil, errors.New("simulated restart failure")
			}
			active[name] = true
		case "stop":
			active[name] = false
		case "disable":
			if len(c.Args) > 1 && c.Args[1] == "--now" {
				active[name] = false
			}
		}
		return nil, nil
	}
}

func TestNativeInstallAndUninstallPreserveUserData(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux symlink/service filesystem contract")
	}
	a := testApp(t)
	active := map[string]bool{}
	fakeSystem(t, a, active, nil)
	source := filepath.Join(a.o.RootDir, "release")
	fixtureAssets(t, source)
	a.o.AssetsDir = source
	a.o.Executable = filepath.Join(source, "subflow")
	writeTest(t, a.o.Executable, []byte("native executable"))
	users := a.path("/etc/sing-box-manager/user-manager.json")
	writeTest(t, users, []byte(`{"users":[{"name":"alice"}]}`))
	writeTest(t, a.path(envPath), []byte("SUBFLOW_API_TOKEN=keep-token\n"))
	if err := a.install(context.Background(), arguments{yes: true}, false); err != nil {
		t.Fatal(err)
	}
	if !active["subflow.service"] || !active["subflow-sync.timer"] || !active["subflow-maintenance.timer"] {
		t.Fatalf("services not enabled: %v", active)
	}
	for _, alias := range []string{"s", "sf"} {
		target, err := os.Readlink(a.path("/usr/local/bin/" + alias))
		if err != nil || target != binaryPath {
			t.Fatalf("alias %s: %s %v", alias, target, err)
		}
	}
	if !fileExists(a.path("/opt/subflow/package-lock.json")) || !fileExists(a.path("/opt/subflow/cloudflare/build.ts")) {
		t.Fatal("release layout not installed")
	}
	if err := a.uninstall(context.Background(), false, true); err != nil {
		t.Fatal(err)
	}
	if fileExists(a.path(binaryPath)) {
		t.Fatal("shared binary should be removed when no kernel remains")
	}
	for _, p := range []string{users, a.path(envPath), a.path("/opt/subflow/cloudflare/build.ts")} {
		if !fileExists(p) {
			t.Fatalf("data removed: %s", p)
		}
	}
}

func TestInstallRollsBackFailedAPIReadiness(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux symlink/service filesystem contract")
	}
	a := testApp(t)
	active := map[string]bool{"subflow.service": true}
	fakeSystem(t, a, active, nil)
	a.o.CheckAPI = func(context.Context, string, string) error { return errors.New("readiness failed") }
	source := filepath.Join(a.o.RootDir, "release")
	fixtureAssets(t, source)
	a.o.AssetsDir = source
	a.o.Executable = filepath.Join(source, "subflow")
	writeTest(t, a.o.Executable, []byte("candidate"))
	writeTest(t, a.path(binaryPath), []byte("old binary"))
	writeTest(t, a.path(envPath), []byte("SUBFLOW_API_TOKEN=old-token\n"))
	writeTest(t, a.path(unitDir+"subflow.service"), []byte("old unit"))
	writeTest(t, a.path("/opt/subflow/cloudflare/build.ts"), []byte("old gateway build"))
	writeTest(t, a.path("/opt/subflow/package-lock.json"), []byte("old lockfile"))
	err := a.install(context.Background(), arguments{yes: true}, false)
	if err == nil || !strings.Contains(err.Error(), "readiness failed") {
		t.Fatalf("expected failure: %v", err)
	}
	for p, want := range map[string]string{a.path(binaryPath): "old binary", a.path(envPath): "SUBFLOW_API_TOKEN=old-token\n", a.path(unitDir + "subflow.service"): "old unit", a.path("/opt/subflow/cloudflare/build.ts"): "old gateway build", a.path("/opt/subflow/package-lock.json"): "old lockfile"} {
		b, _ := os.ReadFile(p)
		if string(b) != want {
			t.Fatalf("%s not restored: %q", p, b)
		}
	}
	if !active["subflow.service"] {
		t.Fatal("previous active service was not restarted")
	}
}

func TestInstallActivatesOnlyEnrolledAgent(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux symlink/service filesystem contract")
	}
	for _, tc := range []struct {
		name, state string
		active, bad bool
	}{
		{name: "standalone"},
		{name: "pending", state: `{"server_id":"","instance_id":"pending"}`},
		{name: "enrolled", state: `{"server_id":"registered-server"}`, active: true},
		{name: "malformed", state: `{`, bad: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := testApp(t)
			active := map[string]bool{}
			fakeSystem(t, a, active, nil)
			source := filepath.Join(a.o.RootDir, "release")
			fixtureAssets(t, source)
			a.o.AssetsDir = source
			a.o.Executable = filepath.Join(source, "subflow")
			writeTest(t, a.o.Executable, []byte("native executable"))
			writeTest(t, a.path(envPath), []byte("SUBFLOW_API_TOKEN=keep-token\nSUBFLOW_USER_DB_PATH=/etc/subflow/custom-users.json\n"))
			if tc.state != "" {
				writeTest(t, a.path("/etc/subflow/custom-users.json.central"), []byte(tc.state))
			}
			err := a.install(context.Background(), arguments{yes: true}, false)
			if tc.bad {
				if err == nil || !strings.Contains(err.Error(), "invalid agent enrollment state") {
					t.Fatalf("expected invalid enrollment error, got %v", err)
				}
				if fileExists(a.path(binaryPath)) || active["subflow-agent.service"] {
					t.Fatal("malformed enrollment changed installed runtime")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if active["subflow-agent.service"] != tc.active {
				t.Fatalf("agent active=%v; want %v", active["subflow-agent.service"], tc.active)
			}
		})
	}
}

func TestKernelInstallValidatesConfigAndPreservesUsers(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux symlink/service filesystem contract")
	}
	data := archiveFixture(t, map[string][]byte{"sing-box": []byte("verified kernel")})
	sum := sha256.Sum256(data)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "sha256sum.txt") {
			fmt.Fprintf(w, "%x sing-box-linux-amd64.tar.gz\n", sum)
		} else {
			w.Write(data)
		}
	}))
	defer server.Close()
	a := testApp(t)
	a.o.ReleaseBase = server.URL
	active := map[string]bool{}
	fakeSystem(t, a, active, nil)
	execute := a.o.Execute
	a.o.Execute = func(ctx context.Context, c Command) ([]byte, error) {
		if n := len(c.Args); n >= 3 && c.Args[n-3] == "manager" && c.Args[n-2] == "system" &&
			c.Args[n-1] == "prepare-restart" {
			t.Fatal("fresh kernel installation attempted to stop an absent service")
		}
		return execute(ctx, c)
	}
	config := a.path("/etc/sing-box/config.json")
	writeTest(t, config, []byte(`{"custom":true}`))
	users := a.path("/etc/sing-box-manager/user-manager.json")
	writeTest(t, users, []byte("preserve"))
	if err := a.installKernel(context.Background(), "v1.0.0"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(config)
	if string(b) != `{"custom":true}` {
		t.Fatal("existing kernel configuration modified")
	}
	b, _ = os.ReadFile(users)
	if string(b) != "preserve" {
		t.Fatal("user data modified")
	}
	if !active["sing-box.service"] {
		t.Fatal("kernel service not started")
	}
	b, _ = os.ReadFile(a.path("/etc/sing-box/.installed_release"))
	if string(b) != "v1.0.0\n" {
		t.Fatalf("stamp %q", b)
	}
}

func TestAPIHealthUsesExactBearerToken(t *testing.T) {
	var authorization string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		if r.URL.Path != "/healthz" {
			t.Error(r.URL.Path)
		}
		w.WriteHeader(200)
	}))
	defer server.Close()
	hostport := strings.TrimPrefix(server.URL, "http://")
	host, port, ok := strings.Cut(hostport, ":")
	if !ok {
		t.Fatal(hostport)
	}
	a := testApp(t)
	err := a.checkAPI(context.Background(), map[string]string{"SUBFLOW_LISTEN_HOST": host, "SUBFLOW_LISTEN_PORT": port, "SUBFLOW_API_TOKEN": "exact token"})
	if err != nil {
		t.Fatal(err)
	}
	if authorization != "Bearer exact token" {
		t.Fatalf("authorization %q", authorization)
	}
}
