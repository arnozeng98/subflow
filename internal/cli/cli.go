package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"
)

type Runner func(context.Context, []string, io.Reader, io.Writer, io.Writer) error

type App struct {
	Manager Runner
	Deploy  Runner
	Serve   Runner
	Version string
	In      io.Reader
	Out     io.Writer
	Err     io.Writer
}

func (a App) Run(ctx context.Context, executable string, args []string) error {
	if len(args) == 0 {
		if strings.TrimSuffix(filepath.Base(executable), ".exe") == "s" {
			return a.Manager(ctx, []string{"menu"}, a.In, a.Out, a.Err)
		}
		return a.Deploy(ctx, []string{"menu"}, a.In, a.Out, a.Err)
	}
	switch args[0] {
	case "version", "--version", "-v":
		_, err := fmt.Fprintln(a.Out, "subflow", a.Version)
		return err
	case "help", "--help", "-h":
		_, err := io.WriteString(a.Out, Help)
		return err
	case "serve":
		return a.Serve(ctx, args[1:], a.In, a.Out, a.Err)
	case "manager":
		if len(args) == 1 {
			return a.Manager(ctx, []string{"menu"}, a.In, a.Out, a.Err)
		}
		return a.Manager(ctx, args[1:], a.In, a.Out, a.Err)
	case "agent", "user", "users", "protocol", "node", "relay", "warp", "export", "config", "system", "service":
		if args[0] == "users" {
			args = append([]string{"user"}, args[1:]...)
		}
		return a.Manager(ctx, args, a.In, a.Out, a.Err)
	case "sync", "--periodic-sync":
		return a.Manager(ctx, []string{"sync"}, a.In, a.Out, a.Err)
	case "maintenance", "--daily-maintenance":
		managerErr := a.Manager(ctx, []string{"maintenance"}, a.In, a.Out, a.Err)
		deployErr := a.Deploy(ctx, []string{"maintenance"}, a.In, a.Out, a.Err)
		return errors.Join(managerErr, deployErr)
	case "--user-watch", "--maintain-logs", "--refresh-upstream":
		_, err := fmt.Fprintln(a.Err, "obsolete scheduler entry ignored; reinstall to migrate to subflow timers")
		return err
	case "install", "edit", "status", "info", "start", "stop", "restart", "enable", "disable", "logs",
		"update", "uninstall", "deploy", "kernel", "menu", "time-sync":
		return a.Deploy(ctx, args, a.In, a.Out, a.Err)
	default:
		return fmt.Errorf("unknown command %q; run subflow help", args[0])
	}
}

const Help = `subflow - sing-box management and per-user subscriptions

Usage: subflow [--env-file PATH] COMMAND [ARGS]

  serve                  Run the private data API
  manager                Open sing-box management
  agent                  Enroll, synchronize or run the central node agent
  user                   Manage users, permissions and quotas
  protocol               Manage inbound protocols
  relay                  Manage full-node and rule-based relays
  warp                   Manage WARP rule routing
  export                 Export client node links
  config                 Inspect and apply sing-box configuration
  system / service       Accounted sing-box lifecycle operations
  sync                   Synchronize usage and user controls
  maintenance            Run scheduled maintenance
  install / update       Install or update subflow
  kernel                 Install/update/manage the sing-box runtime
  time-sync              Synchronize the system clock
  deploy                 Deploy Cloudflare Pages and Tunnel
  edit / info            Manage deployment configuration
  status / start / stop / restart / logs
  uninstall              Remove subflow, retaining sing-box and user data
  version                Print the subflow version

Compatibility: sf opens the deployment menu; s opens the manager.
Business dates use Asia/Shanghai by default. Never edit generated runtime
configuration while a management operation is in progress.
`
