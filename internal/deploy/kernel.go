package deploy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/arnozeng98/subflow/internal/state"
)

const initialKernelConfig = `{
  "log": {"level":"info","output":"/var/log/sing-box/access.log","timestamp":true},
  "inbounds": [],
  "outbounds": [{"type":"direct","tag":"direct"},{"type":"block","tag":"reject"}],
  "route": {"rules":[],"final":"reject"},
  "experimental": {"cache_file":{"enabled":true}}
}
`

func (a *app) kernelControl(ctx context.Context, operation string) error {
	env, err := a.environment()
	if err != nil {
		return err
	}
	executable := a.o.Executable
	if executable == "" {
		executable = a.path(binaryPath)
	}
	args := []string{"manager", "system", operation}
	if fileExists(a.path(envPath)) {
		args = append([]string{"--env-file", a.path(envPath)}, args...)
	}
	processEnv := make([]string, 0, len(os.Environ())+len(env))
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if _, replaced := env[key]; !replaced {
			processEnv = append(processEnv, entry)
		}
	}
	for _, key := range sortedKeys(env) {
		processEnv = append(processEnv, key+"="+env[key])
	}
	_, err = a.o.Execute(ctx, Command{Name: executable, Args: args, Env: processEnv, Stdout: a.out, Stderr: a.errOut})
	if err != nil {
		return fmt.Errorf("accounted kernel %s: %w", operation, err)
	}
	return nil
}

func (a *app) installKernel(ctx context.Context, version string) error {
	env, err := a.environment()
	if err != nil {
		return err
	}
	config := env["SUBFLOW_CONFIG_PATH"]
	if !strings.HasPrefix(config, "/") || strings.ContainsAny(config, "\r\n\x00%\"") {
		return errors.New("kernel config path must be absolute and contain no systemd specifiers/quotes")
	}
	files, tag, err := a.release(ctx, "sing-box", version)
	if err != nil {
		return err
	}
	return a.transaction(ctx, func(t *transaction) error {
		stage := a.path(kernelPath + ".subflow-candidate-" + t.id)
		if err := t.write(stage, files["sing-box"], 0755); err != nil {
			return err
		}
		b, err := a.o.Execute(ctx, Command{Name: stage, Args: []string{"version"}})
		if err != nil {
			return fmt.Errorf("candidate cannot execute (Alpine may need gcompat): %w", err)
		}
		if !strings.Contains(string(b), "with_v2ray_api") {
			return errors.New("candidate missing mandatory with_v2ray_api build tag")
		}
		p := a.path(config)
		if !fileExists(p) {
			if err := t.write(p, []byte(initialKernelConfig), 0600); err != nil {
				return err
			}
		}
		if err := a.cmd(ctx, stage, "check", "-c", p); err != nil {
			return fmt.Errorf("candidate rejected preserved sing-box configuration: %w", err)
		}
		if err := t.service(ctx, "sing-box.service"); err != nil {
			return err
		}
		needsStop := fileExists(a.path(unitDir + "sing-box.service"))
		for _, service := range t.services {
			needsStop = needsStop || (service.name == "sing-box.service" && service.active)
		}
		if needsStop {
			if err := a.kernelControl(ctx, "prepare-restart"); err != nil {
				return err
			}
		}
		if err := t.write(a.path(kernelPath), files["sing-box"], 0755); err != nil {
			return err
		}
		if err := t.remove(stage); err != nil {
			return err
		}
		unit := "[Unit]\nDescription=subflow managed sing-box\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nExecStart=" + kernelPath + " -D /var/lib/sing-box -c \"" + config + "\" run\nRestart=on-failure\nRestartSec=3\nLimitNOFILE=1048576\n\n[Install]\nWantedBy=multi-user.target\n"
		if err := t.write(a.path(unitDir+"sing-box.service"), []byte(unit), 0644); err != nil {
			return err
		}
		for _, dir := range []string{"/var/lib/sing-box", "/var/log/sing-box"} {
			if err := os.MkdirAll(a.path(dir), 0755); err != nil {
				return err
			}
		}
		if err := t.symlink(a.path("/usr/bin/sing-box"), kernelPath); err != nil {
			return err
		}
		if err := t.activate(ctx, "sing-box.service"); err != nil {
			return err
		}
		if err := t.write(a.path("/etc/sing-box/.installed_release"), []byte(tag+"\n"), 0644); err != nil {
			return err
		}
		cache, _ := json.Marshal(map[string]any{"tag": tag, "fetched_at": time.Now().Unix()})
		return t.write(a.path("/etc/sing-box-manager/.upstream-tag-cache"), cache, 0600)
	})
}

func (a *app) kernelInfo(ctx context.Context) error {
	p := a.path(kernelPath)
	if !fileExists(p) {
		fmt.Fprintln(a.out, "sing-box not installed")
		return nil
	}
	if err := a.cmd(ctx, p, "version"); err != nil {
		return err
	}
	if b, err := os.ReadFile(a.path("/etc/sing-box/.installed_release")); err == nil {
		fmt.Fprintf(a.out, "Installed release: %s", b)
	}
	if b, err := os.ReadFile(a.path("/etc/sing-box-manager/.upstream-tag-cache")); err == nil {
		fmt.Fprintf(a.out, "Cached upstream: %s\n", b)
	}
	fmt.Fprintln(a.out, "Schedules: subflow status --service sync; subflow status --service maintenance")
	return nil
}

// MaintainLogs keeps the newest maxBytes in the same inode so a running kernel's
// open log descriptor is not orphaned. Call while holding the manager lock.
func MaintainLogs(path string, maxBytes int64) error {
	if maxBytes <= 0 {
		return errors.New("log retention must be positive")
	}
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	if !st.Mode().IsRegular() {
		return errors.New("log is not a regular file")
	}
	if st.Size() <= maxBytes {
		return nil
	}
	if _, err = f.Seek(-maxBytes, io.SeekEnd); err != nil {
		return err
	}
	b, err := io.ReadAll(io.LimitReader(f, maxBytes))
	if err != nil {
		return err
	}
	if _, err = f.WriteAt(b, 0); err != nil {
		return err
	}
	if err = f.Truncate(int64(len(b))); err != nil {
		return err
	}
	return f.Sync()
}

// RefreshKernelVersion updates the local menu cache without touching the kernel.
func RefreshKernelVersion(ctx context.Context, o Options) error {
	if o.DryRun {
		return nil
	}
	if o.ReleaseAPI == "" {
		o.ReleaseAPI = "https://api.github.com/repos/arnozeng98/subflow/releases"
	}
	if o.HTTPClient == nil {
		o.HTTPClient = defaultHTTPClient()
	}
	if o.Arch == "" {
		o.Arch = runtime.GOARCH
	}
	a := &app{o: o}
	tag, err := a.latestTag(ctx, "sing-box")
	if err != nil {
		return err
	}
	return state.WriteJSON(a.path("/etc/sing-box-manager/.upstream-tag-cache"), map[string]any{"tag": tag, "fetched_at": time.Now().Unix()})
}

func legacyCron(line string) bool {
	fields := strings.Fields(line)
	if len(fields) < 3 || strings.HasPrefix(strings.TrimSpace(line), "#") {
		return false
	}
	// Match the owned command, not arbitrary lines containing similar substrings.
	i := 5
	if strings.HasPrefix(fields[0], "@") {
		i = 1
	}
	if len(fields) <= i {
		return false
	}
	switch fields[i] {
	case "bash", "/bin/bash", "/usr/bin/bash":
		i++
	}
	if len(fields) <= i+1 || (fields[i] != "/root/sb.sh" && fields[i] != "/root/sing-box.sh") {
		return false
	}
	switch fields[i+1] {
	case "--user-watch", "--maintain-logs", "--refresh-upstream", "--periodic-sync", "--daily-maintenance":
		return true
	}
	return false
}

func (a *app) migrateCron(ctx context.Context, t *transaction) error {
	original, err := a.o.Execute(ctx, Command{Name: "crontab", Args: []string{"-l"}})
	if err != nil {
		text := strings.ToLower(string(original))
		if strings.Contains(text, "no crontab") || errors.Is(err, os.ErrNotExist) || strings.Contains(err.Error(), "executable file not found") {
			return nil
		}
		return fmt.Errorf("read legacy cron without losing unrelated entries: %w", err)
	}
	var kept []string
	changed := false
	for _, line := range strings.Split(string(original), "\n") {
		if legacyCron(line) {
			changed = true
		} else {
			kept = append(kept, line)
		}
	}
	if !changed {
		return nil
	}
	updated := []byte(strings.TrimRight(strings.Join(kept, "\n"), "\n") + "\n")
	// Register before mutation to cover a subprocess failing after writing.
	t.undos = append(t.undos, func(ctx context.Context) error {
		_, err := a.o.Execute(ctx, Command{Name: "crontab", Args: []string{"-"}, Stdin: bytes.NewReader(original)})
		return err
	})
	_, err = a.o.Execute(ctx, Command{Name: "crontab", Args: []string{"-"}, Stdin: bytes.NewReader(updated)})
	return err
}

func (a *app) timeSync(ctx context.Context) error {
	// Never kill unrelated processes or execute remote package-install scripts.
	var found string
	for _, service := range []string{"chrony.service", "chronyd.service"} {
		if _, err := a.o.Execute(ctx, Command{Name: "systemctl", Args: []string{"cat", service}}); err == nil {
			found = service
			break
		}
	}
	if found == "" {
		return errors.New("chrony service not installed; install chrony with your distribution package manager (containers may require host time synchronization)")
	}
	if err := a.cmd(ctx, "systemctl", "enable", "--now", found); err != nil {
		return err
	}
	short, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := a.cmd(short, "chronyc", "tracking"); err != nil {
		return err
	}
	return a.cmd(short, "chronyc", "-a", "makestep")
}

// AssetDirectory resolves release layouts for callers embedding the deploy UI.
func AssetDirectory(executable string) string {
	return filepath.Join(filepath.Dir(executable), "cloudflare")
}
