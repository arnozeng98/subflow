package deploy

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

func TestKernelConfigurationAndRestartFailuresRollback(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux symlink/service filesystem contract")
	}
	data := archiveFixture(t, map[string][]byte{"sing-box": []byte("new kernel")})
	sum := sha256.Sum256(data)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "sha256sum.txt") {
			fmt.Fprintf(w, "%x sing-box-linux-amd64.tar.gz\n", sum)
		} else {
			w.Write(data)
		}
	}))
	defer server.Close()
	for _, failure := range []string{"configuration", "accounting", "restart"} {
		t.Run(failure, func(t *testing.T) {
			a := testApp(t)
			a.o.ReleaseBase = server.URL
			active := map[string]bool{"sing-box.service": true}
			failRestart := failure == "restart"
			fakeSystem(t, a, active, &failRestart)
			system := a.o.Execute
			var accounting, startedBinaries []string
			a.o.Execute = func(ctx context.Context, c Command) ([]byte, error) {
				if c.Name == "systemctl" && len(c.Args) > 1 && c.Args[len(c.Args)-1] == "sing-box.service" &&
					(c.Args[0] == "restart" || c.Args[0] == "stop") {
					t.Fatal("kernel lifecycle bypassed accounting")
				}
				if n := len(c.Args); n >= 3 && c.Args[n-3] == "manager" && c.Args[n-2] == "system" {
					operation := c.Args[n-1]
					binary, err := os.ReadFile(a.path(kernelPath))
					if err != nil {
						t.Fatal(err)
					}
					if len(accounting) == 0 && (operation != "prepare-restart" || string(binary) != "old kernel") {
						t.Fatalf("kernel replaced before accounting: %s, %s", operation, binary)
					}
					accounting = append(accounting, operation)
					if failure == "accounting" {
						return nil, errors.New("statistics unavailable")
					}
					if operation == "start" {
						startedBinaries = append(startedBinaries, string(binary))
					}
				}
				if failure == "configuration" && len(c.Args) > 0 && c.Args[0] == "check" {
					return nil, errors.New("invalid existing config")
				}
				return system(ctx, c)
			}
			writeTest(t, a.path(kernelPath), []byte("old kernel"))
			writeTest(t, a.path("/etc/sing-box/config.json"), []byte(`{"retained":true}`))
			writeTest(t, a.path(unitDir+"sing-box.service"), []byte("old unit"))
			err := a.installKernel(context.Background(), "v1.0.0")
			if err == nil {
				t.Fatal("failure swallowed")
			}
			for p, want := range map[string]string{a.path(kernelPath): "old kernel", a.path("/etc/sing-box/config.json"): `{"retained":true}`, a.path(unitDir + "sing-box.service"): "old unit"} {
				b, err := os.ReadFile(p)
				if err != nil || string(b) != want {
					t.Fatalf("not restored %s: %q %v", p, b, err)
				}
			}
			if !active["sing-box.service"] {
				t.Fatal("old service not restored")
			}
			switch failure {
			case "configuration":
				if len(accounting) != 0 {
					t.Fatal("invalid candidate disrupted the existing runtime")
				}
			case "accounting":
				if !reflect.DeepEqual(accounting, []string{"prepare-restart", "prepare-restart"}) {
					t.Fatalf("accounting failure resumed unaccounted traffic: %v", accounting)
				}
			case "restart":
				if !reflect.DeepEqual(accounting, []string{"prepare-restart", "start", "prepare-restart", "start"}) ||
					!reflect.DeepEqual(startedBinaries, []string{"new kernel", "old kernel"}) {
					t.Fatalf("unsafe rollback: operations=%v binaries=%v", accounting, startedBinaries)
				}
			}
		})
	}
}

func TestKernelServiceCommandsUseAccounting(t *testing.T) {
	for _, operation := range []string{"start", "stop", "restart", "enable", "disable"} {
		t.Run(operation, func(t *testing.T) {
			var calls [][]string
			sentinel := errors.New("accounting rejected operation")
			err := RunWithOptions(t.Context(), []string{"kernel", operation}, nil, nil, nil, Options{
				RootDir: t.TempDir(),
				Execute: func(_ context.Context, c Command) ([]byte, error) {
					calls = append(calls, c.Args)
					return nil, sentinel
				},
			})
			if !errors.Is(err, sentinel) || !reflect.DeepEqual(calls, [][]string{{"manager", "system", operation}}) {
				t.Fatalf("calls=%v err=%v", calls, err)
			}
		})
	}
}
