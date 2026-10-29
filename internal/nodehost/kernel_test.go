package nodehost

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/arnozeng98/subflow/internal/state"
)

func optionalKernel(t *testing.T, feature string) string {
	t.Helper()
	binary := os.Getenv("NODEHOST_TEST_SINGBOX")
	if binary == "" {
		t.Skip("set NODEHOST_TEST_SINGBOX to a verified sing-box binary")
	}
	version, err := exec.Command(binary, "version").CombinedOutput()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(version), feature) {
		t.Skip("binary lacks " + feature)
	}
	return binary
}

func freeAddress(t *testing.T) (string, int) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	return address, port
}

func TestVerifiedKernelNativeACMEConfiguration(t *testing.T) {
	binary := optionalKernel(t, "with_acme")
	h := testHost(t)
	addNode(t, h, "trojan", "edge", 24443)
	h.opts.Command = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if name == "sing-box" && len(args) > 0 && args[0] == "version" {
			return exec.CommandContext(ctx, binary, args...).CombinedOutput()
		}
		return nil, nil
	}
	token := filepath.Join(filepath.Dir(h.opts.Config.MetaPath), "dummy-cloudflare-token")
	if err := os.WriteFile(token, []byte("NON_SECRET_CONFIGURATION_TEST_TOKEN"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := h.configureACME(context.Background(), "edge", "node.example.com", "admin@example.com", token, "auto", "letsencrypt"); err != nil {
		t.Fatal(err)
	}
	if err := state.WriteJSON(h.opts.Config.ConfigPath, h.config); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, binary, "check", "-c", h.opts.Config.ConfigPath)
	// Config checking must not issue a real certificate or use real credentials.
	command.Env = append(os.Environ(), "HTTP_PROXY=http://127.0.0.1:1", "HTTPS_PROXY=http://127.0.0.1:1", "NO_PROXY=")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("native ACME configuration check: %v\n%s", err, output)
	}
}

func TestVerifiedKernelTrafficAndNativeGRPCAccounting(t *testing.T) {
	binary := optionalKernel(t, "with_v2ray_api")
	socksAddress, port := freeAddress(t)
	statsAddress, _ := freeAddress(t)
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", port)
	object(object(h.config["experimental"])["v2ray_api"])["listen"] = statsAddress
	if err := state.WriteJSON(h.opts.Config.ConfigPath, h.config); err != nil {
		t.Fatal(err)
	}
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		conn, err := echo.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		io.Copy(conn, conn)
	}()
	cmd := exec.Command(binary, "run", "-c", h.opts.Config.ConfigPath)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	var conn net.Conn
	deadline := time.Now().Add(5 * time.Second)
	for {
		conn, err = net.DialTimeout("tcp", socksAddress, 100*time.Millisecond)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("kernel did not become ready")
		}
		time.Sleep(20 * time.Millisecond)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	conn.Write([]byte{5, 1, 2})
	reply := make([]byte, 2)
	if _, err := io.ReadFull(conn, reply); err != nil || reply[1] != 2 {
		t.Fatal("SOCKS authentication negotiation failed", err)
	}
	credential := h.db.Users["alice"].Credentials["edge"]
	name, password := text(credential["username"]), text(credential["password"])
	auth := append([]byte{1, byte(len(name))}, []byte(name)...)
	auth = append(auth, byte(len(password)))
	auth = append(auth, []byte(password)...)
	conn.Write(auth)
	if _, err := io.ReadFull(conn, reply); err != nil || reply[1] != 0 {
		t.Fatal("ordinary credential rejected", err)
	}
	echoPort := echo.Addr().(*net.TCPAddr).Port
	conn.Write([]byte{5, 1, 0, 1, 127, 0, 0, 1, byte(echoPort >> 8), byte(echoPort)})
	connectReply := make([]byte, 10)
	if _, err := io.ReadFull(conn, connectReply); err != nil || connectReply[1] != 0 {
		t.Fatal("authorized route failed", err)
	}
	payload := bytes.Repeat([]byte("counted-traffic"), 100)
	conn.Write(payload)
	received := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, received); err != nil || !bytes.Equal(payload, received) {
		t.Fatal("traffic echo failed", err)
	}
	conn.Close()
	var stats []Stat
	up, down := int64(0), int64(0)
	for time.Now().Before(deadline) {
		stats, err = QueryStats(context.Background(), statsAddress)
		if err == nil {
			for _, stat := range stats {
				if strings.Contains(stat.Name, "@admin") {
					t.Fatal("admin included in live counter API")
				}
				if stat.Name == "user>>>edge@alice>>>traffic>>>uplink" {
					up = stat.Value
				}
				if stat.Name == "user>>>edge@alice>>>traffic>>>downlink" {
					down = stat.Value
				}
			}
			if up >= int64(len(payload)) && down >= int64(len(payload)) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil || up < int64(len(payload)) || down < int64(len(payload)) {
		t.Fatalf("native QueryStats missing traffic: up=%d down=%d err=%v stats=%v", up, down, err, stats)
	}
	h.opts.Stats = func(ctx context.Context, _ string) ([]Stat, error) { return QueryStats(ctx, statsAddress) }
	if err := h.sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	firstUp, firstDown := h.db.Users["alice"].Up, h.db.Users["alice"].Down
	if err := h.sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	if firstUp != up || firstDown != down || h.db.Users["alice"].Up != up || h.db.Users["alice"].Down != down {
		t.Fatal("runtime snapshots double-counted")
	}
	t.Log(fmt.Sprintf("verified native gRPC traffic: uplink=%d downlink=%d", up, down))
}
