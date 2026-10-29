package deploy

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

func defaultHTTPClient() *http.Client { return &http.Client{Timeout: 3 * time.Minute} }

type cfClient struct {
	a     *app
	token string
}
type cfError struct {
	Status int
	Codes  []int
}

func (e *cfError) Error() string {
	return fmt.Sprintf("Cloudflare request failed (HTTP %d, codes %v); check token validity and Account Pages Edit, Tunnel Edit, Zone DNS Edit, Zone Read permissions", e.Status, e.Codes)
}

func (c cfClient) request(ctx context.Context, method, p string, body, result any) error {
	var data []byte
	var err error
	if body != nil {
		data, err = json.Marshal(body)
		if err != nil {
			return err
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(c.a.o.CloudflareAPI, "/")+p, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.a.o.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	var envelope struct {
		Success bool            `json:"success"`
		Result  json.RawMessage `json:"result"`
		Errors  []struct {
			Code int `json:"code"`
		} `json:"errors"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&envelope); err != nil {
		return fmt.Errorf("Cloudflare %s %s returned invalid JSON (HTTP %d)", method, req.URL.Path, resp.StatusCode)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 || !envelope.Success {
		e := &cfError{Status: resp.StatusCode}
		for _, v := range envelope.Errors {
			e.Codes = append(e.Codes, v.Code)
		}
		return e
	}
	if result != nil {
		if err := json.Unmarshal(envelope.Result, result); err != nil {
			return fmt.Errorf("Cloudflare result: %w", err)
		}
	}
	return nil
}

var accountID = regexp.MustCompile(`^[0-9a-fA-F]{32}$`)
var projectName = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,57}[a-z0-9]$|^[a-z0-9]$`)
var dnsName = regexp.MustCompile(`^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$`)

func (a *app) cloudflareInputs(f arguments) (arguments, string, error) {
	token := os.Getenv("CLOUDFLARE_API_TOKEN")
	fmt.Fprintln(a.out, "Required Cloudflare token permissions: Account Pages Edit; Account Tunnel Edit; Zone DNS Edit; Zone Read. Credentials are not stored.")
	if !f.yes {
		var err error
		if token == "" {
			token, err = a.ask("Cloudflare API token (or set CLOUDFLARE_API_TOKEN)", "")
			if err != nil {
				return f, "", err
			}
		}
		for _, v := range []struct {
			name string
			p    *string
		}{{"Account ID", &f.account}, {"Zone domain", &f.zone}, {"Pages project", &f.project}} {
			*v.p, err = a.ask(v.name, *v.p)
			if err != nil {
				return f, "", err
			}
		}
		if f.subHost == "" {
			f.subHost = "subflow." + f.zone
		}
		if f.apiHost == "" {
			f.apiHost = "api." + f.subHost
		}
		f.subHost, err = a.ask("Subscription hostname", f.subHost)
		if err != nil {
			return f, "", err
		}
		f.apiHost, err = a.ask("API tunnel hostname", f.apiHost)
		if err != nil {
			return f, "", err
		}
	}
	if f.subHost == "" {
		f.subHost = "subflow." + f.zone
	}
	if f.apiHost == "" {
		f.apiHost = "api." + f.subHost
	}
	if token == "" || strings.ContainsAny(token, "\r\n\x00") {
		return f, "", errors.New("CLOUDFLARE_API_TOKEN is required")
	}
	if !accountID.MatchString(f.account) {
		return f, "", errors.New("--account must be a 32-character Cloudflare account ID")
	}
	if !projectName.MatchString(f.project) {
		return f, "", errors.New("invalid Pages project name")
	}
	f.zone = strings.ToLower(f.zone)
	f.subHost = strings.ToLower(f.subHost)
	f.apiHost = strings.ToLower(f.apiHost)
	for _, domain := range []string{f.zone, f.subHost, f.apiHost} {
		if !dnsName.MatchString(domain) || !strings.Contains(domain, ".") || strings.Contains(domain, "..") || len(domain) > 253 {
			return f, "", fmt.Errorf("invalid DNS hostname %q", domain)
		}
	}
	if !strings.HasSuffix(f.subHost, "."+f.zone) || !strings.HasSuffix(f.apiHost, "."+f.zone) || f.subHost == f.apiHost {
		return f, "", errors.New("distinct subscription/API subdomains must belong to --zone")
	}
	return f, token, nil
}

func (c cfClient) permissions(ctx context.Context, f arguments) (string, error) {
	var token struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if err := c.request(ctx, "GET", "/user/tokens/verify", nil, &token); err != nil {
		return "", err
	}
	if token.Status != "active" {
		return "", errors.New("Cloudflare token is not active")
	}
	// The zone response supplies effective zone permissions when available.
	var zones []struct {
		ID      string `json:"id"`
		Account struct {
			ID string `json:"id"`
		} `json:"account"`
		Permissions []string `json:"permissions"`
	}
	q := url.Values{"name": {f.zone}, "account.id": {f.account}}
	if err := c.request(ctx, "GET", "/zones?"+q.Encode(), nil, &zones); err != nil {
		return "", err
	}
	if len(zones) != 1 || zones[0].Account.ID != f.account {
		return "", errors.New("zone not uniquely accessible in selected Cloudflare account")
	}
	if len(zones[0].Permissions) > 0 {
		permissions := strings.Join(zones[0].Permissions, " ")
		if !strings.Contains(permissions, "#dns_records:edit") || !strings.Contains(permissions, "#zone:read") {
			return "", errors.New("token lacks Zone DNS Edit or Zone Read")
		}
	}
	for _, p := range []string{"/accounts/" + f.account + "/pages/projects", "/accounts/" + f.account + "/cfd_tunnel?is_deleted=false", "/zones/" + zones[0].ID + "/dns_records?per_page=1"} {
		if err := c.request(ctx, "GET", p, nil, nil); err != nil {
			return "", err
		}
	}
	// Token policy introspection is optional: normal scoped deployment tokens do
	// not possess User API Tokens Read. Write calls still enforce effective scopes.
	if token.ID != "" {
		var details struct {
			Policies []struct {
				Effect string `json:"effect"`
				Groups []struct {
					Name string `json:"name"`
				} `json:"permission_groups"`
			} `json:"policies"`
		}
		if err := c.request(ctx, "GET", "/user/tokens/"+url.PathEscape(token.ID), nil, &details); err == nil && len(details.Policies) > 0 {
			var names []string
			for _, policy := range details.Policies {
				if policy.Effect == "allow" {
					for _, g := range policy.Groups {
						names = append(names, strings.ToLower(g.Name))
					}
				}
			}
			for _, want := range []string{"pages", "tunnel", "dns"} {
				found := false
				for _, name := range names {
					if strings.Contains(name, want) && (strings.Contains(name, "write") || strings.Contains(name, "edit")) {
						found = true
					}
				}
				if !found {
					return "", fmt.Errorf("Cloudflare token policy missing %s Edit", want)
				}
			}
		}
	}
	return zones[0].ID, nil
}

func (a *app) deployCloudflare(ctx context.Context, f arguments) error {
	f, token, err := a.cloudflareInputs(f)
	if err != nil {
		return err
	}
	env, err := a.environment()
	if err != nil {
		return err
	}
	if env["SUBFLOW_API_TOKEN"] == "" {
		return errors.New("install/configure the VPS API token before Cloudflare deployment")
	}
	if err := a.checkAPI(ctx, env); err != nil {
		return fmt.Errorf("start the local subflow API before Cloudflare deployment: %w", err)
	}
	c := cfClient{a: a, token: token}
	zone, err := c.permissions(ctx, f)
	if err != nil {
		return err
	}
	dir := a.o.AssetsDir
	if dir == "" {
		dir = a.path(assetsPath)
	}
	assets, err := readAssets(dir)
	if err != nil {
		return err
	}
	if err = validateAssets(assets); err != nil {
		return err
	}
	var manifest struct {
		DevDependencies map[string]string `json:"devDependencies"`
		Dependencies    map[string]string `json:"dependencies"`
	}
	if err = json.Unmarshal(assets["package.json"], &manifest); err != nil {
		return err
	}
	pin := manifest.DevDependencies["wrangler"]
	if pin == "" {
		pin = manifest.Dependencies["wrangler"]
	}
	if !regexp.MustCompile(`^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?$`).MatchString(pin) {
		return errors.New("Cloudflare package.json must pin an exact Wrangler version")
	}
	return a.transaction(ctx, func(t *transaction) error {
		work := a.path("/opt/subflow/cloudflare-build-" + t.id)
		if err := os.MkdirAll(work, 0700); err != nil {
			return err
		}
		defer func() {
			if err := removeBuildDirectory(work); err != nil {
				fmt.Fprintln(a.errOut, "build cleanup:", err)
			}
		}()
		for _, name := range sortedKeys(assets) {
			p := filepath.Join(work, filepath.FromSlash(name))
			if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
				return err
			}
			if err := os.WriteFile(p, assets[name], 0600); err != nil {
				return err
			}
		}
		commands := [][]string{{"ci", "--ignore-scripts", "--no-audit", "--no-fund"}}
		if len(assets["cloudflare/dist/_worker.js"]) == 0 {
			commands = append(commands, []string{"run", "build"})
		}
		for _, args := range commands {
			name := "npm"
			if a.npmCLI != "" {
				name = a.nodePath
				args = append([]string{a.npmCLI}, args...)
			}
			if _, err := a.o.Execute(ctx, Command{Name: name, Args: args, Dir: work, Env: a.nodeEnvironment("", "", work), Stdout: a.out, Stderr: a.errOut}); err != nil {
				return fmt.Errorf("Cloudflare build requires Node.js and npm: %w", err)
			}
		}
		account := "/accounts/" + f.account
		project := account + "/pages/projects/" + f.project
		var existing map[string]any
		err := c.request(ctx, "GET", project, nil, &existing)
		if err != nil {
			var ce *cfError
			if !errors.As(err, &ce) || ce.Status != 404 {
				return err
			}
			if err = c.request(ctx, "POST", account+"/pages/projects", map[string]any{"name": f.project, "production_branch": "main"}, &existing); err != nil {
				return err
			}
			t.undos = append(t.undos, func(ctx context.Context) error { return c.request(ctx, "DELETE", project, nil, nil) })
		}
		subdomain, _ := existing["subdomain"].(string)
		if subdomain == "" {
			subdomain = f.project + ".pages.dev"
		}
		tunnel, err := c.ensureTunnel(ctx, t, account, f.project)
		if err != nil {
			return err
		}
		if err = c.configureTunnel(ctx, t, account, tunnel, f.apiHost, originURL(env)); err != nil {
			return err
		}
		if err = a.tunnelService(ctx, t, c, account, tunnel); err != nil {
			return err
		}
		if err = c.ensureDNS(ctx, t, zone, f.apiHost, tunnel+".cfargotunnel.com"); err != nil {
			return err
		}
		// Pages PATCH merges individual env vars (the same operation Wrangler's
		// secret put uses). Never resend redacted values of unrelated secrets.
		production := nestedMap(existing, "deployment_configs", "production")
		merged := map[string]any{}
		merged["VPS_API_BASE_URL"] = map[string]any{"type": "secret_text", "value": "https://" + f.apiHost}
		merged["VPS_API_BEARER_TOKEN"] = map[string]any{"type": "secret_text", "value": env["SUBFLOW_API_TOKEN"]}
		config := map[string]any{"env_vars": merged}
		if hash, ok := production["wrangler_config_hash"]; ok {
			config["wrangler_config_hash"] = hash
		}
		body := map[string]any{"deployment_configs": map[string]any{"production": config}}
		if err = c.request(ctx, "PATCH", project, body, nil); err != nil {
			return err
		}
		// Secret values may be redacted by the API, so never claim they can be
		// reconstructed on rollback. Persisted local API token remains authoritative.
		fmt.Fprintln(a.out, "Pages production secrets set; if a later step fails, rerun deployment (previous encrypted values cannot always be read back).")
		wrangler := filepath.Join(work, "node_modules", "wrangler", "bin", "wrangler.js")
		if !fileExists(wrangler) {
			return errors.New("pinned local Wrangler executable missing after npm ci")
		}
		if !fileExists(filepath.Join(work, "cloudflare", "dist", "_worker.js")) {
			return errors.New("build did not produce cloudflare/dist/_worker.js")
		}
		node := "node"
		if a.nodePath != "" {
			node = a.nodePath
		}
		if _, err = a.o.Execute(ctx, Command{Name: node, Args: []string{wrangler, "pages", "deploy", "dist", "--project-name", f.project, "--branch", "main", "--commit-dirty=true"}, Dir: filepath.Join(work, "cloudflare"), Env: a.nodeEnvironment(token, f.account, work), Stdout: a.out, Stderr: a.errOut}); err != nil {
			return err
		}
		var domains []struct {
			Name string `json:"name"`
		}
		if err = c.request(ctx, "GET", project+"/domains", nil, &domains); err != nil {
			return err
		}
		exists := false
		for _, domain := range domains {
			if domain.Name == f.subHost {
				exists = true
			}
		}
		if !exists {
			if err = c.request(ctx, "POST", project+"/domains", map[string]string{"name": f.subHost}, nil); err != nil {
				return err
			}
			t.undos = append(t.undos, func(ctx context.Context) error {
				return c.request(ctx, "DELETE", project+"/domains/"+url.PathEscape(f.subHost), nil, nil)
			})
		}
		if err = c.ensureDNS(ctx, t, zone, f.subHost, subdomain); err != nil {
			return err
		}
		fmt.Fprintf(a.out, "Cloudflare deployed: https://%s/<username> (TLS/DNS activation may take several minutes). API uses outbound-only tunnel.\n", f.subHost)
		return nil
	})
}

func nestedMap(m map[string]any, keys ...string) map[string]any {
	for _, k := range keys {
		next, ok := m[k].(map[string]any)
		if !ok {
			return map[string]any{}
		}
		m = next
	}
	return m
}

func cleanCloudflareEnv(token, account, work string) []string {
	var env []string
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		switch key {
		case "CLOUDFLARE_API_KEY", "CLOUDFLARE_EMAIL", "CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID", "CF_API_KEY", "CF_API_EMAIL", "CF_API_TOKEN", "XDG_CONFIG_HOME", "WRANGLER_SEND_METRICS":
			continue
		}
		env = append(env, entry)
	}
	env = append(env, "XDG_CONFIG_HOME="+filepath.Join(work, ".config"), "WRANGLER_SEND_METRICS=false")
	if token != "" {
		env = append(env, "CLOUDFLARE_API_TOKEN="+token, "CLOUDFLARE_ACCOUNT_ID="+account)
	}
	return env
}

func (c cfClient) ensureTunnel(ctx context.Context, t *transaction, account, name string) (string, error) {
	var tunnels []struct {
		ID string `json:"id"`
	}
	if err := c.request(ctx, "GET", account+"/cfd_tunnel?"+url.Values{"name": {name}, "is_deleted": {"false"}}.Encode(), nil, &tunnels); err != nil {
		return "", err
	}
	if len(tunnels) > 1 {
		return "", errors.New("multiple same-name tunnels; choose a distinct project name")
	}
	if len(tunnels) == 1 {
		return tunnels[0].ID, nil
	}
	var tunnel struct {
		ID string `json:"id"`
	}
	if err := c.request(ctx, "POST", account+"/cfd_tunnel", map[string]string{"name": name, "config_src": "cloudflare"}, &tunnel); err != nil {
		return "", err
	}
	if tunnel.ID == "" {
		return "", errors.New("Cloudflare returned empty tunnel ID")
	}
	t.undos = append(t.undos, func(ctx context.Context) error {
		return c.request(ctx, "DELETE", account+"/cfd_tunnel/"+tunnel.ID, nil, nil)
	})
	return tunnel.ID, nil
}

func (c cfClient) configureTunnel(ctx context.Context, t *transaction, account, id, hostname, origin string) error {
	p := account + "/cfd_tunnel/" + id + "/configurations"
	var original map[string]any
	if err := c.request(ctx, "GET", p, nil, &original); err != nil {
		return err
	}
	old := nestedMap(original, "config")
	config := map[string]any{}
	for k, v := range old {
		config[k] = v
	}
	var ingress []any
	var catchall any
	if items, ok := old["ingress"].([]any); ok {
		for _, item := range items {
			rule, ok := item.(map[string]any)
			if !ok {
				return errors.New("invalid existing tunnel ingress")
			}
			host, _ := rule["hostname"].(string)
			if host == hostname {
				continue
			}
			if host == "" {
				catchall = item
				continue
			}
			ingress = append(ingress, item)
		}
	}
	ingress = append(ingress, map[string]string{"hostname": hostname, "service": origin})
	if catchall == nil {
		catchall = map[string]string{"service": "http_status:404"}
	}
	ingress = append(ingress, catchall)
	config["ingress"] = ingress
	t.undos = append(t.undos, func(ctx context.Context) error { return c.request(ctx, "PUT", p, map[string]any{"config": old}, nil) })
	return c.request(ctx, "PUT", p, map[string]any{"config": config}, nil)
}

func (c cfClient) ensureDNS(ctx context.Context, t *transaction, zone, host, target string) error {
	p := "/zones/" + zone + "/dns_records"
	var records []map[string]any
	if err := c.request(ctx, "GET", p+"?"+url.Values{"name": {host}}.Encode(), nil, &records); err != nil {
		return err
	}
	body := map[string]any{"type": "CNAME", "name": host, "content": target, "proxied": true, "ttl": 1}
	if len(records) > 1 {
		return fmt.Errorf("DNS %s has multiple records; refusing destructive consolidation", host)
	}
	if len(records) == 1 {
		record := records[0]
		id, _ := record["id"].(string)
		typ, _ := record["type"].(string)
		if typ != "CNAME" && typ != "A" && typ != "AAAA" {
			return fmt.Errorf("DNS %s has unrelated %s record; refusing replacement", host, typ)
		}
		if id == "" {
			return errors.New("DNS response missing record ID")
		}
		original := map[string]any{}
		for _, key := range []string{"type", "name", "content", "ttl", "proxied", "comment", "tags", "settings"} {
			if v, ok := record[key]; ok {
				original[key] = v
			}
		}
		for _, key := range []string{"comment", "tags", "settings"} {
			if v, ok := record[key]; ok {
				body[key] = v
			}
		}
		t.undos = append(t.undos, func(ctx context.Context) error { return c.request(ctx, "PUT", p+"/"+id, original, nil) })
		return c.request(ctx, "PUT", p+"/"+id, body, nil)
	}
	var record struct {
		ID string `json:"id"`
	}
	if err := c.request(ctx, "POST", p, body, &record); err != nil {
		return err
	}
	if record.ID == "" {
		return errors.New("DNS creation returned empty ID")
	}
	t.undos = append(t.undos, func(ctx context.Context) error { return c.request(ctx, "DELETE", p+"/"+record.ID, nil, nil) })
	return nil
}

func (a *app) tunnelService(ctx context.Context, t *transaction, c cfClient, account, id string) error {
	const service = "subflow-cloudflared.service"
	if err := t.service(ctx, service); err != nil {
		return err
	}
	p := a.path("/usr/local/bin/cloudflared")
	if !fileExists(p) {
		data, err := a.cloudflaredBinary(ctx)
		if err != nil {
			return err
		}
		stage := p + ".subflow-candidate-" + t.id
		if err = t.write(stage, data, 0755); err != nil {
			return err
		}
		if err = a.cmd(ctx, stage, "--version"); err != nil {
			return err
		}
		if err = t.write(p, data, 0755); err != nil {
			return err
		}
		if err = t.remove(stage); err != nil {
			return err
		}
	} else {
		if err := a.cmd(ctx, p, "--version"); err != nil {
			return err
		}
	}
	var token string
	if err := c.request(ctx, "GET", account+"/cfd_tunnel/"+id+"/token", nil, &token); err != nil {
		return err
	}
	if token == "" || strings.ContainsAny(token, "'\r\n\x00") {
		return errors.New("invalid tunnel runtime token")
	}
	if err := t.write(a.path("/etc/subflow/cloudflared.env"), []byte("TUNNEL_TOKEN='"+token+"'\n"), 0600); err != nil {
		return err
	}
	unit := "[Unit]\nDescription=subflow Cloudflare tunnel\nAfter=network-online.target subflow.service\nWants=network-online.target\n\n[Service]\nType=simple\nEnvironmentFile=/etc/subflow/cloudflared.env\nExecStart=/usr/local/bin/cloudflared --no-autoupdate tunnel run\nRestart=on-failure\nRestartSec=5\nNoNewPrivileges=true\n\n[Install]\nWantedBy=multi-user.target\n"
	if err := t.write(a.path(unitDir+service), []byte(unit), 0644); err != nil {
		return err
	}
	return t.activate(ctx, service)
}

func (a *app) cloudflaredBinary(ctx context.Context) ([]byte, error) {
	if a.o.Arch != "amd64" && a.o.Arch != "arm64" {
		return nil, errors.New("cloudflared supports Linux amd64/arm64")
	}
	b, err := a.get(ctx, a.o.CloudflaredAPI, 4<<20)
	if err != nil {
		return nil, err
	}
	var release struct {
		Assets []struct {
			Name   string `json:"name"`
			URL    string `json:"browser_download_url"`
			Digest string `json:"digest"`
		} `json:"assets"`
	}
	if err = json.Unmarshal(b, &release); err != nil {
		return nil, err
	}
	for _, asset := range release.Assets {
		if asset.Name != "cloudflared-linux-"+a.o.Arch {
			continue
		}
		expected, err := hex.DecodeString(strings.TrimPrefix(asset.Digest, "sha256:"))
		if err != nil || len(expected) != 32 || !strings.HasPrefix(asset.Digest, "sha256:") {
			return nil, errors.New("cloudflared release lacks SHA-256 digest; install a verified binary manually")
		}
		data, err := a.get(ctx, asset.URL, downloadLimit)
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(data)
		if !bytes.Equal(sum[:], expected) {
			return nil, errors.New("cloudflared SHA-256 mismatch")
		}
		return data, nil
	}
	return nil, errors.New("cloudflared Linux asset not found")
}

func removeBuildDirectory(dir string) error {
	if !strings.HasPrefix(filepath.Base(dir), "cloudflare-build-") {
		return errors.New("refusing to clean unowned build directory")
	}
	return os.RemoveAll(dir)
}

// NewToken returns a cryptographically random token for embedding applications.
func NewToken() (string, error) {
	b := make([]byte, 32)
	_, err := rand.Read(b)
	return hex.EncodeToString(b), err
}
