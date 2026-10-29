package deploy

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"testing"
)

func TestDebianMissingDependenciesInstallWithApt(t *testing.T) {
	for _, version := range []string{"12", "13"} {
		t.Run(version, func(t *testing.T) {
			a := testApp(t)
			writeTest(t, a.path("/etc/os-release"), []byte("ID=debian\nVERSION_ID=\""+version+"\"\n"))
			installed := false
			var calls []string
			a.o.LookPath = func(name string) (string, error) {
				if name == "apt-get" || installed {
					return "/usr/bin/" + name, nil
				}
				return "", exec.ErrNotFound
			}
			a.o.Execute = func(_ context.Context, c Command) ([]byte, error) {
				if c.Name != "apt-get" {
					t.Fatalf("unexpected executable %s", c.Name)
				}
				calls = append(calls, strings.Join(c.Args, " "))
				if c.Args[0] == "install" {
					installed = true
					writeTest(t, a.path("/etc/ssl/certs/ca-certificates.crt"), []byte("certificates"))
				}
				return nil, nil
			}
			if err := a.ensureHostDependencies(context.Background(), true, true); err != nil {
				t.Fatal(err)
			}
			if len(calls) != 2 || calls[0] != "update" || !strings.Contains(calls[1], "systemd ca-certificates chrony") {
				t.Fatalf("apt calls %v", calls)
			}
		})
	}
}

func TestDebianDependenciesDeclinedBeforeMutation(t *testing.T) {
	a := testApp(t)
	writeTest(t, a.path("/etc/os-release"), []byte("ID=debian\nVERSION_ID=12\n"))
	a.in = bufio.NewReader(strings.NewReader("no\n"))
	a.o.LookPath = func(name string) (string, error) {
		if name == "apt-get" {
			return "/usr/bin/apt-get", nil
		}
		return "", exec.ErrNotFound
	}
	a.o.Execute = func(context.Context, Command) ([]byte, error) {
		t.Fatal("declined dependency installation executed command")
		return nil, nil
	}
	if err := a.ensureHostDependencies(context.Background(), false, false); err == nil || !strings.Contains(err.Error(), "cancelled") {
		t.Fatalf("expected refusal: %v", err)
	}
	if fileExists(a.path("/opt/subflow")) {
		t.Fatal("declined install mutated runtime")
	}
}

func TestDebianAptFailureIsExplicit(t *testing.T) {
	a := testApp(t)
	writeTest(t, a.path("/etc/os-release"), []byte("ID=debian\nVERSION_ID=13\n"))
	a.o.LookPath = func(name string) (string, error) {
		if name == "apt-get" {
			return name, nil
		}
		return "", exec.ErrNotFound
	}
	a.o.Execute = func(context.Context, Command) ([]byte, error) { return nil, errors.New("mirror unavailable") }
	err := a.ensureHostDependencies(context.Background(), true, false)
	if err == nil || !strings.Contains(err.Error(), "apt-get update") || !strings.Contains(err.Error(), "mirror unavailable") {
		t.Fatalf("unexpected apt error %v", err)
	}
	if fileExists(a.path("/usr/local/bin/subflow")) {
		t.Fatal("runtime installed after apt failure")
	}
}

func TestGoAPIInstallDoesNotRequireNode(t *testing.T) {
	a := testApp(t)
	writeTest(t, a.path("/etc/ssl/certs/ca-certificates.crt"), []byte("certificates"))
	var looked []string
	a.o.LookPath = func(name string) (string, error) {
		looked = append(looked, name)
		if name == "systemctl" {
			return name, nil
		}
		return "", exec.ErrNotFound
	}
	a.o.Execute = func(context.Context, Command) ([]byte, error) { t.Fatal("unexpected install command"); return nil, nil }
	if err := a.ensureHostDependencies(context.Background(), true, false); err != nil {
		t.Fatal(err)
	}
	if strings.Join(looked, ",") != "systemctl" {
		t.Fatalf("Go API introduced extra runtime deps %v", looked)
	}
}

func TestNodeChecksumFailureDoesNotModifyHost(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/index.json":
			io.WriteString(w, `[{"version":"v24.1.0"}]`)
		case strings.HasSuffix(r.URL.Path, "SHASUMS256.txt"):
			fmt.Fprintf(w, "%s node-v24.1.0-linux-x64.tar.gz\n", strings.Repeat("0", 64))
		default:
			io.WriteString(w, "corrupt tar")
		}
	}))
	defer server.Close()
	a := testApp(t)
	a.o.NodeIndex = server.URL + "/index.json"
	a.o.NodeBase = server.URL
	a.o.LookPath = func(string) (string, error) { return "", exec.ErrNotFound }
	a.o.Execute = func(context.Context, Command) ([]byte, error) { t.Fatal("unverified Node executed"); return nil, nil }
	err := a.ensureNode(context.Background(), true)
	if err == nil || !strings.Contains(err.Error(), "SHA-256 mismatch") {
		t.Fatalf("expected checksum failure: %v", err)
	}
	if fileExists(a.path("/opt/subflow/node")) {
		t.Fatal("unverified runtime written")
	}
}

func TestOfficialNodeRuntimeInstallsWithoutReplacingSystemNode(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux runtime symlink contract")
	}
	data := archiveFixture(t, map[string][]byte{
		"node-v24.1.0-linux-x64/bin/node":                            []byte("node binary"),
		"node-v24.1.0-linux-x64/lib/node_modules/npm/bin/npm-cli.js": []byte("npm cli"),
		"node-v24.1.0-linux-x64/lib/node_modules/npm/bin/npx-cli.js": []byte("npx cli"),
	})
	sum := sha256.Sum256(data)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/index.json":
			io.WriteString(w, `[{"version":"v25.0.0"},{"version":"v24.1.0"}]`)
		case strings.HasSuffix(r.URL.Path, "SHASUMS256.txt"):
			fmt.Fprintf(w, "%x node-v24.1.0-linux-x64.tar.gz\n", sum)
		default:
			w.Write(data)
		}
	}))
	defer server.Close()
	a := testApp(t)
	a.o.NodeIndex = server.URL + "/index.json"
	a.o.NodeBase = server.URL
	writeTest(t, a.path("/usr/bin/node"), []byte("system node kept"))
	a.o.LookPath = func(string) (string, error) { return "", exec.ErrNotFound }
	a.o.Execute = func(context.Context, Command) ([]byte, error) { return []byte("v24.1.0\n"), nil }
	if err := a.ensureNode(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	if a.nodePath != a.path("/opt/subflow/node/v24.1.0/bin/node") || a.npmCLI == "" {
		t.Fatalf("runtime not selected %s %s", a.nodePath, a.npmCLI)
	}
	got, err := os.ReadFile(a.path("/usr/bin/node"))
	if err != nil || !bytes.Equal(got, []byte("system node kept")) {
		t.Fatal("system Node replaced")
	}
	target, err := os.Readlink(a.path("/opt/subflow/node/v24.1.0/bin/npm"))
	if err != nil || target != "../lib/node_modules/npm/bin/npm-cli.js" {
		t.Fatalf("npm shortcut %s %v", target, err)
	}
}
