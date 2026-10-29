package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/arnozeng98/subflow/internal/api"
	"github.com/arnozeng98/subflow/internal/cli"
	"github.com/arnozeng98/subflow/internal/deploy"
	"github.com/arnozeng98/subflow/internal/nodehost"
	"github.com/arnozeng98/subflow/internal/settings"
)

var version = "dev"

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args); err != nil {
		fmt.Fprintln(os.Stderr, "subflow:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) error {
	envPath := os.Getenv("SUBFLOW_ENV_FILE")
	explicit := envPath != ""
	if envPath == "" {
		envPath = "/etc/subflow/subflow.env"
	}
	commands := args[1:]
	if len(commands) > 0 && commands[0] == "--env-file" {
		if len(commands) < 2 {
			return errors.New("--env-file requires a path")
		}
		envPath, explicit = commands[1], true
		commands = commands[2:]
	}
	if err := settings.LoadEnvFile(envPath); err != nil && (explicit || !errors.Is(err, os.ErrNotExist)) {
		return err
	}
	deploy.ManagerRun = nodehost.Run
	app := cli.App{
		Manager: nodehost.Run, Deploy: deploy.Run,
		Serve: serve, Version: version, In: os.Stdin, Out: os.Stdout, Err: os.Stderr,
	}
	return app.Run(ctx, args[0], commands)
}

func serve(ctx context.Context, args []string, _ io.Reader, _, errOut io.Writer) error {
	if len(args) != 0 {
		return errors.New("serve does not accept positional arguments; configure SUBFLOW_* environment variables")
	}
	c, err := settings.Load()
	if err != nil {
		return err
	}
	return api.Serve(ctx, c, slog.New(slog.NewJSONHandler(errOut, nil)))
}
