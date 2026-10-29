// Package deploy owns host installation and service lifecycle, not subscription business logic.
package deploy

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/arnozeng98/subflow/internal/state"
)

const (
	binaryPath = "/usr/local/bin/subflow"
	envPath    = "/etc/subflow/subflow.env"
	assetsPath = "/opt/subflow/cloudflare"
	kernelPath = "/usr/local/bin/sing-box"
	unitDir    = "/etc/systemd/system/"
)

// Command describes an external executable. No command is interpreted by a shell.
type Command struct {
	Name           string
	Args           []string
	Dir            string
	Env            []string
	Stdin          io.Reader
	Stdout, Stderr io.Writer
}

type Executor func(context.Context, Command) ([]byte, error)

// ManagerRun lets the root executable share its interactive input with the
// business manager, without spawning another process or importing its package.
var ManagerRun func(context.Context, []string, io.Reader, io.Writer, io.Writer) error

// Options permits hermetic host, network and process injection. RootDir is for
// tests/staging only: it redirects filesystem writes, not systemctl's target.
type Options struct {
	RootDir        string
	AssetsDir      string
	Executable     string
	HTTPClient     *http.Client
	Execute        Executor
	CheckAPI       func(context.Context, string, string) error
	LookPath       func(string) (string, error)
	NodeIndex      string
	NodeBase       string
	ReleaseAPI     string
	ReleaseBase    string
	CloudflareAPI  string
	CloudflaredAPI string
	Arch           string
	DryRun         bool
}

type app struct {
	o                Options
	in               *bufio.Reader
	rawIn            io.Reader
	out, errOut      io.Writer
	nodePath, npmCLI string
}

type arguments struct {
	yes, dry, reveal, follow                                           bool
	withKernel, withCloudflare                                         bool
	assets, version, service, account, zone, subHost, apiHost, project string
	sets                                                               assignments
	lines                                                              int
}

type assignments []string

func (s *assignments) String() string     { return strings.Join(*s, ",") }
func (s *assignments) Set(v string) error { *s = append(*s, v); return nil }

func Run(ctx context.Context, args []string, in io.Reader, out, errOut io.Writer) error {
	return RunWithOptions(ctx, args, in, out, errOut, Options{})
}

func RunWithOptions(ctx context.Context, args []string, in io.Reader, out, errOut io.Writer, o Options) error {
	if in == nil {
		in = strings.NewReader("")
	}
	if out == nil {
		out = io.Discard
	}
	if errOut == nil {
		errOut = io.Discard
	}
	if o.HTTPClient == nil {
		o.HTTPClient = &http.Client{Timeout: 3 * time.Minute}
	}
	if o.Execute == nil {
		o.Execute = execute
	}
	if o.ReleaseAPI == "" {
		o.ReleaseAPI = "https://api.github.com/repos/arnozeng98/subflow/releases"
	}
	if o.ReleaseBase == "" {
		o.ReleaseBase = "https://github.com/arnozeng98/subflow/releases/download"
	}
	if o.CloudflareAPI == "" {
		o.CloudflareAPI = "https://api.cloudflare.com/client/v4"
	}
	if o.CloudflaredAPI == "" {
		o.CloudflaredAPI = "https://api.github.com/repos/cloudflare/cloudflared/releases/latest"
	}
	if o.Arch == "" {
		o.Arch = runtime.GOARCH
	}
	if o.Executable == "" {
		var err error
		o.Executable, err = os.Executable()
		if err != nil {
			return err
		}
	}
	if o.AssetsDir == "" {
		o.AssetsDir = os.Getenv("SUBFLOW_ASSETS_DIR")
	}
	a := &app{o: o, in: bufio.NewReader(in), rawIn: in, out: out, errOut: errOut}
	return a.run(ctx, args)
}

func execute(ctx context.Context, c Command) ([]byte, error) {
	cmd := exec.CommandContext(ctx, c.Name, c.Args...)
	cmd.Dir, cmd.Stdin = c.Dir, c.Stdin
	if c.Env != nil {
		cmd.Env = c.Env
	}
	var b bytes.Buffer
	cmd.Stdout = &b
	if c.Stdout != nil {
		// Streaming journal output must not accumulate indefinitely in memory.
		cmd.Stdout = c.Stdout
	}
	cmd.Stderr = c.Stderr
	if cmd.Stderr == nil {
		cmd.Stderr = &b
	}
	err := cmd.Run()
	if err != nil {
		return b.Bytes(), fmt.Errorf("%s failed: %w", filepath.Base(c.Name), err)
	}
	return b.Bytes(), nil
}

func (a *app) path(p string) string {
	if a.o.RootDir == "" {
		return filepath.FromSlash(p)
	}
	return filepath.Join(a.o.RootDir, filepath.FromSlash(strings.TrimLeft(p, "/\\")))
}

func (a *app) cmd(ctx context.Context, name string, args ...string) error {
	if a.o.DryRun {
		fmt.Fprintf(a.out, "dry-run: %s %s\n", name, strings.Join(args, " "))
		return nil
	}
	_, err := a.o.Execute(ctx, Command{Name: name, Args: args, Stdout: a.out, Stderr: a.errOut})
	return err
}

func (a *app) run(ctx context.Context, args []string) error {
	// Accept --dry-run before or after the subcommand.
	filtered := make([]string, 0, len(args))
	for _, arg := range args {
		if arg == "--dry-run" {
			a.o.DryRun = true
		} else {
			filtered = append(filtered, arg)
		}
	}
	args = filtered
	if len(args) == 0 || args[0] == "menu" {
		return a.menu(ctx)
	}
	command := args[0]
	kernel := command == "kernel"
	args = args[1:]
	if kernel {
		if len(args) == 0 {
			return a.kernelMenu(ctx)
		}
		command, args = args[0], args[1:]
		switch command {
		case "install", "update", "uninstall", "info", "status", "logs", "start", "stop", "restart", "enable", "disable", "time-sync":
		default:
			return fmt.Errorf("unsupported kernel operation %q; configuration belongs to subflow manager", command)
		}
	}
	var f arguments
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	fs.SetOutput(a.errOut)
	fs.BoolVar(&f.yes, "yes", false, "noninteractive confirmation")
	fs.BoolVar(&f.reveal, "show-secrets", false, "show API token in info")
	fs.BoolVar(&f.follow, "follow", false, "follow journal")
	fs.BoolVar(&f.withKernel, "with-kernel", false, "also install the verified sing-box kernel")
	fs.BoolVar(&f.withCloudflare, "with-cloudflare", false, "also deploy Cloudflare Pages and tunnel")
	fs.StringVar(&f.assets, "assets", a.o.AssetsDir, "Cloudflare source directory")
	fs.StringVar(&f.version, "version", "latest", "release tag")
	fs.StringVar(&f.service, "service", "subflow", "subflow, agent, sync, maintenance, cloudflared")
	fs.StringVar(&f.account, "account", os.Getenv("CLOUDFLARE_ACCOUNT_ID"), "Cloudflare account ID")
	fs.StringVar(&f.zone, "zone", "", "Cloudflare zone domain")
	fs.StringVar(&f.subHost, "sub-host", "", "subscription hostname")
	fs.StringVar(&f.apiHost, "api-host", "", "tunnel hostname")
	fs.StringVar(&f.project, "project", "subflow", "Pages project name")
	fs.IntVar(&f.lines, "lines", 50, "journal lines")
	fs.Var(&f.sets, "set", "environment KEY=value (repeatable)")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if len(fs.Args()) != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(fs.Args(), " "))
	}
	a.o.AssetsDir = f.assets
	switch command {
	case "info":
		if kernel {
			return a.kernelInfo(ctx)
		}
		return a.info(f.reveal)
	case "status", "logs":
		service, err := serviceName(f.service, kernel)
		if err != nil {
			return err
		}
		if command == "status" {
			return a.cmd(ctx, "systemctl", "status", "--no-pager", service)
		}
		if f.lines < 1 || f.lines > 100000 {
			return errors.New("--lines must be 1..100000")
		}
		jargs := []string{"-u", service, "--no-pager", "-n", fmt.Sprint(f.lines)}
		if f.follow {
			jargs = append(jargs, "-f")
		}
		return a.cmd(ctx, "journalctl", jargs...)
	case "install", "update", "edit", "uninstall", "start", "stop", "restart", "enable", "disable", "deploy", "time-sync", "maintenance":
	default:
		return fmt.Errorf("unknown deployment command %q", command)
	}
	if !a.o.DryRun && a.o.RootDir == "" {
		if runtime.GOOS != "linux" {
			return errors.New("host lifecycle requires Linux with systemd; use --dry-run to preview")
		}
		if os.Geteuid() != 0 {
			return errors.New("host lifecycle requires root")
		}
	}
	if a.o.DryRun {
		fmt.Fprintf(a.out, "dry-run: %s%s; preserve configuration and user data; verify downloads; transactionally replace managed files\n", map[bool]string{true: "kernel ", false: ""}[kernel], command)
		switch command {
		case "install", "update":
			fmt.Fprintln(a.out, "download SHA-256 manifest and matching linux archive; validate staged executable; install units; enable/restart and verify services")
		case "deploy":
			fmt.Fprintln(a.out, "verify Cloudflare token, zone/account and Pages/Tunnel/DNS permissions; preserve existing remote configuration; build pinned Pages assets; provision tunnel service, secrets, custom domain and DNS")
		}
		return nil
	}
	switch command {
	case "install", "update", "deploy", "time-sync":
		if err := a.ensureHostDependencies(ctx, f.yes, command == "time-sync"); err != nil {
			return err
		}
		if command == "deploy" || f.withCloudflare {
			if err := a.ensureNode(ctx, f.yes); err != nil {
				return err
			}
		}
	}
	return state.WithLock(ctx, a.path("/etc/subflow/deploy.lock"), func() error {
		if kernel {
			switch command {
			case "install", "update":
				return a.installKernel(ctx, f.version)
			case "uninstall":
				return a.uninstall(ctx, true, f.yes)
			case "time-sync":
				return a.timeSync(ctx)
			case "maintenance":
				logErr := MaintainLogs(a.path("/var/log/sing-box/access.log"), 10<<20)
				cacheErr := RefreshKernelVersion(ctx, a.o)
				return errors.Join(logErr, cacheErr)
			}
		}
		switch command {
		case "start", "stop", "restart", "enable", "disable":
			if kernel {
				return a.kernelControl(ctx, command)
			}
			service, err := serviceName(f.service, kernel)
			if err != nil {
				return err
			}
			return a.cmd(ctx, "systemctl", command, service)
		case "install":
			if err := a.install(ctx, f, false); err != nil {
				return err
			}
			if f.withKernel {
				if err := a.installKernel(ctx, "latest"); err != nil {
					return fmt.Errorf("subflow installed, kernel setup failed: %w", err)
				}
			}
			if f.withCloudflare {
				if err := a.deployCloudflare(ctx, f); err != nil {
					return fmt.Errorf("subflow installed, Cloudflare deployment failed: %w", err)
				}
			}
			return nil
		case "update":
			return a.install(ctx, f, true)
		case "edit":
			return a.edit(ctx, f)
		case "uninstall":
			return a.uninstall(ctx, false, f.yes)
		case "deploy":
			return a.deployCloudflare(ctx, f)
		case "time-sync":
			return a.timeSync(ctx)
		default:
			return fmt.Errorf("%s is not a kernel operation", command)
		}
	})
}

func serviceName(name string, kernel bool) (string, error) {
	if kernel {
		return "sing-box.service", nil
	}
	services := map[string]string{"subflow": "subflow.service", "agent": "subflow-agent.service", "sync": "subflow-sync.timer", "maintenance": "subflow-maintenance.timer", "cloudflared": "subflow-cloudflared.service"}
	s, ok := services[name]
	if !ok {
		return "", fmt.Errorf("unsupported service %q", name)
	}
	return s, nil
}

func (a *app) ask(label, current string) (string, error) {
	fmt.Fprintf(a.out, "%s [%s]: ", label, current)
	line, err := a.in.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	line = strings.TrimSpace(line)
	if line == "" {
		return current, nil
	}
	return line, nil
}

func (a *app) confirm(label string, yes bool) error {
	if yes {
		return nil
	}
	s, err := a.ask(label+" (type YES)", "no")
	if err != nil {
		return err
	}
	if s != "YES" {
		return errors.New("cancelled; use --yes for noninteractive operation")
	}
	return nil
}

func (a *app) menu(ctx context.Context) error {
	for {
		fmt.Fprintln(a.out, "\nsubflow: 1 status | 2 info | 3 edit | 4 service | 5 logs | 6 update | 7 Cloudflare deploy | 8 uninstall | 9 manager | k kernel | 0 exit")
		s, err := a.ask("Select", "0")
		if err != nil {
			return err
		}
		var args []string
		switch s {
		case "0":
			return nil
		case "1":
			args = []string{"status"}
		case "2":
			args = []string{"info"}
		case "3":
			args = []string{"edit"}
		case "4":
			op, e := a.ask("start / stop / restart / enable / disable", "status")
			if e != nil {
				return e
			}
			args = []string{op}
		case "5":
			args = []string{"logs", "--follow"}
		case "6":
			args = []string{"update"}
		case "7":
			args = []string{"deploy"}
		case "8":
			args = []string{"uninstall"}
		case "9":
			var err error
			if ManagerRun != nil && !a.o.DryRun {
				err = ManagerRun(ctx, []string{"menu"}, a.in, a.out, a.errOut)
			} else if a.o.DryRun {
				err = a.cmd(ctx, a.path(binaryPath), "manager", "menu")
			} else {
				input := io.Reader(a.in)
				if file, ok := a.rawIn.(*os.File); ok {
					input = file
				}
				_, err = a.o.Execute(ctx, Command{Name: a.path(binaryPath), Args: []string{"manager", "menu"}, Stdin: input, Stdout: a.out, Stderr: a.errOut})
			}
			if err != nil {
				fmt.Fprintln(a.errOut, err)
			}
			continue
		case "k":
			if err := a.kernelMenu(ctx); err != nil {
				fmt.Fprintln(a.errOut, err)
			}
			continue
		default:
			fmt.Fprintln(a.errOut, "Unknown selection")
			continue
		}
		if err := a.run(ctx, args); err != nil {
			fmt.Fprintln(a.errOut, err)
		}
	}
}

func (a *app) kernelMenu(ctx context.Context) error {
	for {
		fmt.Fprintln(a.out, "\nsing-box: install | update | info | status | start | stop | restart | enable | disable | logs | time-sync | uninstall | 0 exit\nProtocols/users/routing: subflow manager")
		op, err := a.ask("Operation", "0")
		if err != nil {
			return err
		}
		if op == "0" {
			return nil
		}
		if err := a.run(ctx, []string{"kernel", op}); err != nil {
			fmt.Fprintln(a.errOut, err)
		}
	}
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
