package deploy

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/arnozeng98/subflow/internal/settings"
)

var configKeys = []string{
	"SUBFLOW_PUBLIC_IP", "SUBFLOW_API_TOKEN", "SUBFLOW_LISTEN_HOST", "SUBFLOW_LISTEN_PORT",
	"SUBFLOW_CONFIG_PATH", "SUBFLOW_USER_DB_PATH", "SUBFLOW_META_PATH",
	"SUBFLOW_WS_DOMAIN", "SUBFLOW_VMESS_WS_DOMAIN", "SUBFLOW_INCLUDE_DISABLED_USERS",
	"SUBFLOW_LOCK_PATH", "SUBFLOW_BUSINESS_TIMEZONE",
}

func (a *app) environment() (map[string]string, error) {
	c, err := settings.Defaults()
	if err != nil {
		return nil, err
	}
	env := map[string]string{
		"SUBFLOW_PUBLIC_IP": c.PublicIP, "SUBFLOW_API_TOKEN": c.APIToken,
		"SUBFLOW_LISTEN_HOST": c.ListenHost, "SUBFLOW_LISTEN_PORT": strconv.Itoa(c.ListenPort),
		"SUBFLOW_CONFIG_PATH": c.ConfigPath, "SUBFLOW_USER_DB_PATH": c.UserDBPath,
		"SUBFLOW_META_PATH": c.MetaPath,
		"SUBFLOW_WS_DOMAIN": c.VlessWSDomain, "SUBFLOW_VMESS_WS_DOMAIN": c.VmessWSDomain,
		"SUBFLOW_INCLUDE_DISABLED_USERS": strconv.FormatBool(c.IncludeDisabledUsers),
		"SUBFLOW_LOCK_PATH":              c.LockPath, "SUBFLOW_BUSINESS_TIMEZONE": c.BusinessTimezone,
	}
	b, err := os.ReadFile(a.path(envPath))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err == nil {
		old, e := settings.ReadEnv(bytes.NewReader(b))
		if e != nil {
			return nil, e
		}
		for k, v := range old {
			env[k] = v
		}
	} else {
		for _, k := range configKeys {
			if v, ok := os.LookupEnv(k); ok {
				env[k] = v
			}
		}
	}
	return env, nil
}

func (a *app) configuration(f arguments, interactive bool) (map[string]string, error) {
	env, err := a.environment()
	if err != nil {
		return nil, err
	}
	for _, assignment := range f.sets {
		k, v, ok := strings.Cut(assignment, "=")
		if !ok {
			return nil, fmt.Errorf("--set requires KEY=value")
		}
		known := false
		for _, allowed := range configKeys {
			if k == allowed {
				known = true
			}
		}
		if !known {
			return nil, fmt.Errorf("unknown configuration key %s", k)
		}
		env[k] = v
	}
	if interactive && !f.yes && len(f.sets) == 0 {
		for _, k := range configKeys {
			current := env[k]
			if k == "SUBFLOW_API_TOKEN" {
				current = "(keep/generate)"
				v, e := a.ask(k+" (g regenerates)", current)
				if e != nil {
					return nil, e
				}
				if v == "g" {
					env[k] = ""
				} else if v != current {
					env[k] = v
				}
			} else {
				v, e := a.ask(k+" (- clears)", current)
				if e != nil {
					return nil, e
				}
				if v == "-" {
					v = ""
				}
				env[k] = v
			}
		}
	}
	if env["SUBFLOW_API_TOKEN"] == "" {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			return nil, err
		}
		env["SUBFLOW_API_TOKEN"] = hex.EncodeToString(b)
	}
	if _, err := settings.FromLookup(func(k string) (string, bool) { v, ok := env[k]; return v, ok }); err != nil {
		return nil, err
	}
	for k, v := range env {
		// Quoting must agree with systemd and settings.ReadEnv; use literal single quotes.
		if strings.ContainsAny(v, "\x00\r\n'") {
			return nil, fmt.Errorf("%s contains an unsupported quote or control character", k)
		}
	}
	for _, k := range configKeys {
		v := env[k]
		if strings.HasSuffix(k, "_PATH") && !strings.HasPrefix(v, "/") {
			return nil, fmt.Errorf("%s must be an absolute Linux path", k)
		}
	}
	if host := env["SUBFLOW_LISTEN_HOST"]; host == "" || strings.ContainsAny(host, " \t/") {
		return nil, errors.New("invalid listen host")
	}
	return env, nil
}

func encodeEnvironment(env map[string]string) []byte {
	var b strings.Builder
	b.WriteString("# Managed by subflow edit. Literal values; not a shell script.\n")
	for _, k := range sortedKeys(env) {
		fmt.Fprintf(&b, "%s='%s'\n", k, env[k])
	}
	return []byte(b.String())
}

func (a *app) info(reveal bool) error {
	env, err := a.environment()
	if err != nil {
		return err
	}
	for _, k := range configKeys {
		v := env[k]
		if k == "SUBFLOW_API_TOKEN" && !reveal && v != "" {
			v = "(redacted; use --show-secrets)"
		}
		fmt.Fprintf(a.out, "%s=%s\n", k, v)
	}
	fmt.Fprintf(a.out, "Environment: %s\nBinary: %s\nAssets: %s\n", envPath, binaryPath, assetsPath)
	return nil
}

func serviceUnit(description, command, extra string) []byte {
	return []byte("[Unit]\nDescription=" + description + "\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nEnvironmentFile=" + envPath + "\nExecStart=" + binaryPath + " " + command + "\nRestart=on-failure\nRestartSec=3\n" + extra + "\n[Install]\nWantedBy=multi-user.target\n")
}

func units() map[string][]byte {
	result := map[string][]byte{
		"subflow.service":       serviceUnit("subflow private subscription API", "serve", ""),
		"subflow-agent.service": serviceUnit("subflow central node agent", "agent run", "TimeoutStopSec=45\nExecStopPost=/bin/systemctl stop sing-box.service\n"),
	}
	for name, command := range map[string]string{"sync": "sync", "maintenance": "maintenance"} {
		result["subflow-"+name+".service"] = []byte("[Unit]\nDescription=subflow " + name + "\nAfter=network-online.target\n\n[Service]\nType=oneshot\nEnvironmentFile=" + envPath + "\nExecStart=" + binaryPath + " " + command + "\n")
		schedule := "OnBootSec=3min\nOnUnitActiveSec=3min\n"
		if name == "maintenance" {
			schedule = "OnCalendar=*-*-* 04:47:00\nPersistent=true\n"
		}
		result["subflow-"+name+".timer"] = []byte("[Unit]\nDescription=subflow " + name + " schedule\n\n[Timer]\n" + schedule + "AccuracySec=30s\n\n[Install]\nWantedBy=timers.target\n")
	}
	return result
}

func (a *app) install(ctx context.Context, f arguments, update bool) error {
	env, err := a.configuration(f, !update)
	if err != nil {
		return err
	}
	var binary []byte
	var assets map[string][]byte
	if update {
		bundle, _, e := a.release(ctx, "subflow", f.version)
		if e != nil {
			return e
		}
		binary = bundle["subflow"]
		assets = make(map[string][]byte)
		for name, data := range bundle {
			if strings.HasPrefix(name, "cloudflare/") || name == "package.json" || name == "package-lock.json" || name == "tsconfig.json" {
				assets[name] = data
			}
		}
		if len(assets) == 0 {
			return errors.New("release missing cloudflare sources and package lock")
		}
	} else {
		binary, err = os.ReadFile(a.o.Executable)
		if err != nil {
			return fmt.Errorf("read running executable: %w", err)
		}
		dir := a.o.AssetsDir
		if dir == "" {
			candidate := filepath.Join(filepath.Dir(a.o.Executable), "cloudflare")
			if fileExists(candidate) {
				dir = candidate
			} else if fileExists(a.path(assetsPath)) {
				dir = a.path(assetsPath)
			}
		}
		if dir == "" {
			return errors.New("Cloudflare release assets missing; use --assets /path/to/cloudflare")
		}
		assets, err = readAssets(dir)
		if err != nil {
			return err
		}
	}
	if err := validateAssets(assets); err != nil {
		return err
	}
	err = a.transaction(ctx, func(t *transaction) error {
		managed := units()
		active := []string{"subflow.service", "subflow-sync.timer", "subflow-maintenance.timer"}
		if fileExists(a.path(env["SUBFLOW_USER_DB_PATH"] + ".central")) {
			data, err := os.ReadFile(a.path(env["SUBFLOW_USER_DB_PATH"] + ".central"))
			if err != nil {
				return err
			}
			var enrollment struct {
				ServerID string `json:"server_id"`
			}
			if err := json.Unmarshal(data, &enrollment); err != nil {
				return fmt.Errorf("invalid agent enrollment state: %w", err)
			}
			if enrollment.ServerID != "" {
				active = append(active, "subflow-agent.service")
			}
		}
		for _, name := range sortedKeys(managed) {
			if err := t.service(ctx, name); err != nil {
				return err
			}
		}
		if update {
			stage := a.path(binaryPath + ".subflow-candidate-" + t.id)
			if err := t.write(stage, binary, 0755); err != nil {
				return err
			}
			if err := a.cmd(ctx, stage, "version"); err != nil {
				return fmt.Errorf("release executable validation: %w", err)
			}
			if err := t.remove(stage); err != nil {
				return err
			}
		}
		if err := t.write(a.path(binaryPath), binary, 0755); err != nil {
			return err
		}
		if err := t.write(a.path(envPath), encodeEnvironment(env), 0600); err != nil {
			return err
		}
		for _, name := range sortedKeys(assets) {
			if err := t.write(filepath.Join(a.path("/opt/subflow"), filepath.FromSlash(name)), assets[name], 0644); err != nil {
				return err
			}
		}
		if err := a.trackAssets(t, assets); err != nil {
			return err
		}
		for _, name := range []string{"s", "sf"} {
			if err := t.symlink(a.path("/usr/local/bin/"+name), binaryPath); err != nil {
				return err
			}
		}
		for _, name := range sortedKeys(managed) {
			if err := t.write(a.path(unitDir+name), managed[name], 0644); err != nil {
				return err
			}
		}
		if err := a.migrateCron(ctx, t); err != nil {
			return err
		}
		if err := t.activate(ctx, active...); err != nil {
			return err
		}
		return a.checkAPI(ctx, env)
	})
	if err != nil {
		return err
	}
	fmt.Fprintln(a.out, "subflow installed. Configuration and user data preserved. Commands: sf, s.")
	return nil
}

func (a *app) edit(ctx context.Context, f arguments) error {
	env, err := a.configuration(f, true)
	if err != nil {
		return err
	}
	return a.transaction(ctx, func(t *transaction) error {
		names := []string{"subflow.service", "subflow-agent.service"}
		for _, name := range names {
			if fileExists(a.path(unitDir + name)) {
				if err := t.service(ctx, name); err != nil {
					return err
				}
			}
		}
		if err := t.write(a.path(envPath), encodeEnvironment(env), 0600); err != nil {
			return err
		}
		for _, s := range t.services {
			if s.active {
				if err := a.cmd(ctx, "systemctl", "restart", s.name); err != nil {
					return err
				}
				if err := a.cmd(ctx, "systemctl", "is-active", "--quiet", s.name); err != nil {
					return err
				}
				if s.name == "subflow.service" {
					if err := a.checkAPI(ctx, env); err != nil {
						return err
					}
				}
			}
		}
		return nil
	})
}

func (a *app) uninstall(ctx context.Context, kernel, yes bool) error {
	if err := a.confirm("Remove managed runtime only; retain all environment, user data, assets and logs?", yes); err != nil {
		return err
	}
	return a.transaction(ctx, func(t *transaction) error {
		names := []string{"subflow.service", "subflow-agent.service", "subflow-cloudflared.service", "subflow-sync.timer", "subflow-maintenance.timer", "subflow-sync.service", "subflow-maintenance.service"}
		if kernel {
			names = []string{"sing-box.service", "subflow-agent.service", "subflow-sync.timer", "subflow-maintenance.timer"}
		}
		for _, name := range names {
			p := a.path(unitDir + name)
			if !fileExists(p) {
				continue
			}
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			if !strings.Contains(string(b), binaryPath) && !strings.Contains(string(b), kernelPath) && !strings.HasPrefix(name, "subflow-") {
				return fmt.Errorf("refusing to remove unmanaged unit %s", name)
			}
			if err := t.service(ctx, name); err != nil {
				return err
			}
			if name == "sing-box.service" {
				if err := a.kernelControl(ctx, "prepare-restart"); err != nil {
					return err
				}
			}
			if err := a.cmd(ctx, "systemctl", "disable", "--now", name); err != nil {
				return err
			}
			if !kernel || name == "sing-box.service" {
				if err := t.remove(p); err != nil {
					return err
				}
			}
		}
		if kernel {
			if err := t.remove(a.path(kernelPath)); err != nil {
				return err
			}
			if err := t.remove(a.path("/etc/sing-box/.installed_release")); err != nil {
				return err
			}
			p := a.path("/usr/bin/sing-box")
			if target, _ := os.Readlink(p); target == kernelPath {
				if err := t.remove(p); err != nil {
					return err
				}
			}
		} else {
			// Keep the shared binary and s alias if the sing-box manager still needs them.
			if !fileExists(a.path(kernelPath)) {
				if err := t.remove(a.path(binaryPath)); err != nil {
					return err
				}
				for _, name := range []string{"s", "sf"} {
					p := a.path("/usr/local/bin/" + name)
					if target, _ := os.Readlink(p); target == binaryPath {
						if err := t.remove(p); err != nil {
							return err
						}
					}
				}
			}
		}
		if err := a.migrateCron(ctx, t); err != nil {
			return err
		}
		return a.cmd(ctx, "systemctl", "daemon-reload")
	})
}

func readAssets(dir string) (map[string][]byte, error) {
	result := map[string][]byte{}
	if !fileExists(filepath.Join(dir, "package.json")) && filepath.Base(dir) == "cloudflare" {
		dir = filepath.Dir(dir)
	}
	for _, name := range []string{"package.json", "package-lock.json", "tsconfig.json"} {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, fmt.Errorf("Cloudflare release layout needs root %s: %w", name, err)
		}
		result[name] = b
	}
	err := filepath.WalkDir(filepath.Join(dir, "cloudflare"), func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "node_modules" || d.Name() == ".git" || d.Name() == ".wrangler" {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("asset symlinks are not allowed: %s", p)
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		if strings.HasPrefix(d.Name(), ".env") {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		result[filepath.ToSlash(rel)] = b
		return nil
	})
	return result, err
}

func validateAssets(assets map[string][]byte) error {
	for _, name := range []string{"package.json", "package-lock.json", "tsconfig.json", "cloudflare/build.ts"} {
		if len(assets[name]) == 0 {
			return fmt.Errorf("Cloudflare assets missing %s", name)
		}
	}
	return nil
}

func originURL(env map[string]string) string {
	host := env["SUBFLOW_LISTEN_HOST"]
	if host == "0.0.0.0" {
		host = "127.0.0.1"
	}
	if host == "::" {
		host = "::1"
	}
	return "http://" + net.JoinHostPort(host, env["SUBFLOW_LISTEN_PORT"])
}

func (a *app) checkAPI(ctx context.Context, env map[string]string) error {
	origin, token := originURL(env), env["SUBFLOW_API_TOKEN"]
	if a.o.CheckAPI != nil {
		return a.o.CheckAPI(ctx, origin, token)
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	for {
		req, err := http.NewRequestWithContext(ctx, "GET", origin+"/healthz", nil)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := a.o.HTTPClient.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
			if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
				return errors.New("subflow health check rejected the configured API token")
			}
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("subflow authenticated /healthz did not become ready: %w", ctx.Err())
		case <-time.After(200 * time.Millisecond):
		}
	}
}

func (a *app) trackAssets(t *transaction, assets map[string][]byte) error {
	p := a.path("/opt/subflow/.subflow-assets.json")
	b, err := os.ReadFile(p)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err == nil {
		var old []string
		if err = json.Unmarshal(b, &old); err != nil {
			return fmt.Errorf("read installed asset manifest: %w", err)
		}
		for _, name := range old {
			if _, exists := assets[name]; exists {
				continue
			}
			if !safeAssetName(name) {
				return fmt.Errorf("unsafe installed asset manifest entry %q", name)
			}
			if err := t.remove(filepath.Join(a.path("/opt/subflow"), filepath.FromSlash(name))); err != nil {
				return err
			}
		}
	}
	b, err = json.Marshal(sortedKeys(assets))
	if err != nil {
		return err
	}
	return t.write(p, b, 0600)
}

func safeAssetName(name string) bool {
	if strings.ContainsAny(name, "\\:\x00") || strings.Contains(name, "..") || strings.HasPrefix(name, "/") {
		return false
	}
	return strings.HasPrefix(name, "cloudflare/") || name == "package.json" || name == "package-lock.json" || name == "tsconfig.json"
}
