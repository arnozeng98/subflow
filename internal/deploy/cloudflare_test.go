package deploy

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestCloudflareEndToEndWithInjectedAPIAndProcesses(t *testing.T) {
	account := strings.Repeat("a", 32)
	var mu sync.Mutex
	var secretsSet, uploaded bool
	var patched map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer cf-api-secret" {
			t.Error("missing API authorization")
		}
		var result any = map[string]any{}
		p := r.URL.Path
		switch {
		case p == "/user/tokens/verify":
			result = map[string]any{"id": "token-id", "status": "active"}
		case p == "/user/tokens/token-id":
			w.WriteHeader(http.StatusForbidden)
			io.WriteString(w, `{"success":false,"errors":[{"code":10000}]}`)
			return
		case p == "/zones":
			result = []any{map[string]any{"id": "zone-id", "account": map[string]string{"id": account}, "permissions": []string{"#zone:read", "#dns_records:edit"}}}
		case strings.HasSuffix(p, "/pages/projects/subflow") && r.Method == "PATCH":
			if err := json.NewDecoder(r.Body).Decode(&patched); err != nil {
				t.Error(err)
			}
			secretsSet = true
		case strings.HasSuffix(p, "/pages/projects/subflow"):
			result = map[string]any{"subdomain": "subflow.pages.dev", "deployment_configs": map[string]any{"production": map[string]any{"env_vars": map[string]any{"KEEP_ME": map[string]string{"type": "plain_text", "value": "preserved"}}}}}
		case strings.HasSuffix(p, "/pages/projects"):
			result = []any{}
		case strings.HasSuffix(p, "/cfd_tunnel"):
			result = []any{map[string]string{"id": "tunnel-id"}}
		case strings.HasSuffix(p, "/configurations") && r.Method == "GET":
			result = map[string]any{"config": map[string]any{"ingress": []any{map[string]string{"hostname": "keep.example.com", "service": "http://localhost:9000"}, map[string]string{"service": "http_status:404"}}}}
		case strings.HasSuffix(p, "/token"):
			result = "runtime-tunnel-secret"
		case strings.HasSuffix(p, "/dns_records") && r.Method == "POST":
			result = map[string]string{"id": "record-id"}
		case strings.HasSuffix(p, "/dns_records"):
			result = []any{}
		case strings.HasSuffix(p, "/domains") && r.Method == "GET":
			result = []any{}
		}
		json.NewEncoder(w).Encode(map[string]any{"success": true, "result": result})
	}))
	defer server.Close()
	a := testApp(t)
	a.o.CloudflareAPI = server.URL
	t.Setenv("CLOUDFLARE_API_TOKEN", "cf-api-secret")
	source := filepath.Join(a.o.RootDir, "release")
	fixtureAssets(t, source)
	a.o.AssetsDir = source
	writeTest(t, a.path(envPath), []byte("SUBFLOW_API_TOKEN=api-bearer-secret\n"))
	writeTest(t, a.path("/usr/local/bin/cloudflared"), []byte("verified installed cloudflared"))
	fakeSystem(t, a, map[string]bool{}, nil)
	system := a.o.Execute
	a.o.Execute = func(ctx context.Context, c Command) ([]byte, error) {
		switch c.Name {
		case "npm":
			if c.Args[0] == "ci" {
				writeTest(t, filepath.Join(c.Dir, "node_modules", "wrangler", "bin", "wrangler.js"), []byte("local pinned wrangler"))
			}
			if c.Args[0] == "run" {
				writeTest(t, filepath.Join(c.Dir, "cloudflare", "dist", "_worker.js"), []byte("worker"))
			}
			for _, entry := range c.Env {
				if strings.HasPrefix(entry, "CLOUDFLARE_API_TOKEN=") {
					t.Error("build received deploy credentials")
				}
			}
			return nil, nil
		case "node":
			mu.Lock()
			defer mu.Unlock()
			if !secretsSet {
				t.Error("assets deployed before secrets")
			}
			if filepath.Base(c.Dir) != "cloudflare" {
				t.Fatalf("wrong Wrangler cwd %s", c.Dir)
			}
			if c.Args[1] != "pages" || c.Args[2] != "deploy" || c.Args[3] != "dist" {
				t.Fatalf("unexpected deploy args %v", c.Args)
			}
			uploaded = true
			return nil, nil
		default:
			return system(ctx, c)
		}
	}
	err := a.deployCloudflare(context.Background(), arguments{yes: true, account: account, zone: "example.com", project: "subflow"})
	if err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if !uploaded {
		t.Fatal("Pages assets not uploaded")
	}
	vars := nestedMap(patched, "deployment_configs", "production", "env_vars")
	if _, resent := vars["KEEP_ME"]; resent {
		t.Fatal("unrelated Pages variable should be left untouched, not resent")
	}
	if nestedMap(vars, "VPS_API_BEARER_TOKEN")["value"] != "api-bearer-secret" {
		t.Fatal("wrong Pages bearer token")
	}
	tokenFile := a.path("/etc/subflow/cloudflared.env")
	b, err := os.ReadFile(tokenFile)
	if err != nil || !strings.Contains(string(b), "runtime-tunnel-secret") {
		t.Fatalf("runtime token %q %v", b, err)
	}
	if strings.Contains(string(b), "cf-api-secret") {
		t.Fatal("Cloudflare administrative token persisted")
	}
	matches, _ := filepath.Glob(a.path("/opt/subflow/cloudflare-build-*"))
	if len(matches) != 0 {
		t.Fatalf("build workspace leaked: %v", matches)
	}
}

func TestDNSRollbackPreservesPreviousRecord(t *testing.T) {
	var puts []map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "GET" {
			io.WriteString(w, `{"success":true,"result":[{"id":"record","type":"A","name":"api.example.com","content":"192.0.2.1","ttl":120,"proxied":false,"comment":"owned by user"}]}`)
			return
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		puts = append(puts, body)
		io.WriteString(w, `{"success":true,"result":{}}`)
	}))
	defer server.Close()
	a := testApp(t)
	a.o.CloudflareAPI = server.URL
	err := a.transaction(context.Background(), func(tx *transaction) error {
		if err := (cfClient{a: a, token: "secret"}).ensureDNS(context.Background(), tx, "zone", "api.example.com", "tunnel.cfargotunnel.com"); err != nil {
			return err
		}
		return errors.New("later operation failed")
	})
	if err == nil {
		t.Fatal("failure swallowed")
	}
	if len(puts) != 2 || puts[1]["content"] != "192.0.2.1" || puts[1]["type"] != "A" || puts[1]["comment"] != "owned by user" {
		t.Fatalf("old DNS not restored: %#v", puts)
	}
}

func TestCredentialScopedCloudflarePermissionsFailBeforeWrites(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			t.Error("permission preflight performed mutation")
		}
		if r.URL.Path == "/user/tokens/verify" {
			io.WriteString(w, `{"success":true,"result":{"status":"active"}}`)
			return
		}
		io.WriteString(w, `{"success":true,"result":[{"id":"zone","account":{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"permissions":["#zone:read"]}]}`)
	}))
	defer server.Close()
	a := testApp(t)
	a.o.CloudflareAPI = server.URL
	_, err := (cfClient{a: a, token: "secret"}).permissions(context.Background(), arguments{account: strings.Repeat("a", 32), zone: "example.com"})
	if err == nil || !strings.Contains(err.Error(), "DNS Edit") {
		t.Fatalf("expected DNS scope failure: %v", err)
	}
}
