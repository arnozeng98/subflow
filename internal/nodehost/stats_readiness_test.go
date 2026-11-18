package nodehost

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestAccountedRestartWaitsForStatisticsReadiness(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "socks", "edge", 1080)
	h.db.StatsBlocked = true
	startup, attempts, restarts := false, 0, 0
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "systemctl" && len(args) > 0 && args[0] == "restart" {
			startup, attempts = true, 0
			restarts++
		}
		return nil, nil
	}
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		if startup {
			attempts++
			if attempts < 3 {
				return nil, errors.New("dial tcp: connection refused")
			}
			startup = false
		}
		return []Stat{}, nil
	}
	saveHost(t, h)
	if err := h.run(context.Background(), []string{"user", "add", "--name", "alice", "--nodes", "edge", "--quota-bytes", "67108864"}); err != nil {
		t.Fatal(err)
	}
	if startup || attempts != 3 || h.db.ProbeRequired || h.db.StatsBlocked || h.db.RuntimeStopped || len(h.db.Uncertain) != 0 {
		t.Fatal("accounted startup was quarantined or did not await its RPC")
	}
	if err := h.run(context.Background(), []string{"sync"}); err != nil {
		t.Fatal(err)
	}
	if restarts != 2 || h.db.ProbeRequired || !h.active("alice", "edge") || len(h.db.Uncertain) != 0 {
		t.Fatal("post-probe access apply did not probe its own restart")
	}
	found := false
	for _, raw := range list(object(list(h.config["inbounds"])[0])["users"]) {
		found = found || object(raw)["username"] == "edge@alice"
	}
	if !found {
		t.Fatal("ordinary credential remained withheld after successful readiness")
	}
}

func TestRunningStatisticsFailureDoesNotGetStartupGrace(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	cause := errors.New("established runtime RPC failed")
	calls, stops := 0, 0
	var logs bytes.Buffer
	h.errOut = &logs
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		calls++
		return nil, cause
	}
	h.opts.Command = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name == "systemctl" && len(args) > 0 && args[0] == "stop" {
			stops++
		}
		return nil, nil
	}
	err := h.sample(context.Background())
	if !errors.Is(err, cause) || calls != 1 || stops != 1 || !h.db.RuntimeStopped || !h.db.StatsBlocked || len(h.db.Uncertain) != 1 {
		t.Fatalf("running failure was retried/masked: calls=%d stops=%d error=%v", calls, stops, err)
	}
	if !strings.Contains(logs.String(), cause.Error()) {
		t.Fatal("original failure was not logged")
	}
}

func TestStartupProbeDeadlineRetainsCauseAndFailsClosed(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "socks", "edge", 1080)
	started := false
	cause := errors.New("RPC listener still unavailable")
	h.opts.Command = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if name == "systemctl" && len(args) > 0 && args[0] == "restart" {
			started = true
		}
		return nil, nil
	}
	h.opts.Stats = func(ctx context.Context, _ string) ([]Stat, error) {
		if started {
			deadline, ok := ctx.Deadline()
			if !ok || time.Until(deadline) > 5*time.Second {
				t.Error("startup probe is not bounded")
			}
			return nil, cause
		}
		return []Stat{}, nil
	}
	var logs bytes.Buffer
	h.errOut = &logs
	saveHost(t, h)
	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()
	err := h.run(ctx, []string{"user", "add", "--name", "alice"})
	if !errors.Is(err, cause) || !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(logs.String(), cause.Error()) {
		t.Fatalf("startup cause/deadline was lost: %v; %s", err, logs.String())
	}
	if !h.db.RuntimeStopped || !h.db.StatsBlocked || len(h.db.Uncertain) != 1 || h.db.Users["alice"] == nil {
		t.Fatal("failed committed startup did not preserve and quarantine its user")
	}
}

func TestDefaultNativeStatsEmptyResponseAndDiagnosticErrors(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	protocols := new(http.Protocols)
	protocols.SetUnencryptedHTTP2(true)
	replyStatus := make(chan string, 3)
	replyStatus <- "0"
	replyStatus <- "12"
	replyStatus <- "PRIVATE_RESPONSE_SENTINEL"
	server := &http.Server{Protocols: protocols, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.ProtoMajor != 2 || !bytes.Equal(body, append([]byte{0, 0, 0, 0, 9, 10, 7}, []byte("user>>>")...)) {
			t.Error("default stats is not native HTTP/2 QueryStats with reset=false")
		}
		w.Header().Set("Content-Type", "application/grpc")
		w.Header().Set("Trailer", "Grpc-Status, Grpc-Message")
		w.Write([]byte{0, 0, 0, 0, 0})
		w.Header().Set("Grpc-Status", <-replyStatus)
		w.Header().Set("Grpc-Message", "PRIVATE_MESSAGE_SENTINEL")
	})}
	go server.Serve(listener)
	defer server.Close()
	h := newHost(Options{Command: func(context.Context, string, ...string) ([]byte, error) {
		t.Error("native stats attempted to execute an external program")
		return nil, errors.New("unexpected command")
	}}, io.Discard, io.Discard)
	stats, err := h.opts.Stats(context.Background(), listener.Addr().String())
	if err != nil || len(stats) != 0 {
		t.Fatalf("default empty counters were not accepted: %v %v", stats, err)
	}
	for _, expected := range []string{"grpc-status 12", "grpc-status missing/invalid"} {
		_, err = h.opts.Stats(context.Background(), listener.Addr().String())
		if err == nil || !strings.Contains(err.Error(), "HTTP 200, HTTP/2") || !strings.Contains(err.Error(), expected) || strings.Contains(err.Error(), "PRIVATE_") {
			t.Fatalf("unsafe or missing RPC status diagnostic: %v", err)
		}
	}
	server.Close()
	_, err = h.opts.Stats(context.Background(), listener.Addr().String())
	var operation *net.OpError
	if err == nil || !strings.Contains(err.Error(), "stats RPC connection failed") || !errors.As(err, &operation) {
		t.Fatalf("native transport error was lost: %v", err)
	}
}
