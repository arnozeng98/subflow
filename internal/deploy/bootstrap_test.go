package deploy

import (
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const curlBootstrapStub = `#!/bin/sh
[ "$1" = --disable ] || exit 91
if [ "${DOWNLOAD_FAIL:-0}" != 0 ]; then exit "$DOWNLOAD_FAIL"; fi
destination=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) destination=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *sha256sum.txt) cp "$FIXTURE_MANIFEST" "$destination" ;;
  *) cp "$FIXTURE_ARCHIVE" "$destination" ;;
esac
`

const wgetBootstrapStub = `#!/bin/sh
[ "$1" = --no-config ] || exit 91
destination=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -O) destination=$2; shift 2 ;;
    https://*|http://*) url=$1; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "$REQUEST_LOG"
case "$url" in
  https://github.com/*)
    scheme=https
    [ "${INSECURE_REDIRECT:-0}" != 1 ] || scheme=http
    printf '  HTTP/1.1 302 Found\n  Location: %s://release.example/%s\n' "$scheme" "${url##*/}" >&2
    exit 8
    ;;
  https://release.example/*sha256sum.txt) cp "$FIXTURE_MANIFEST" "$destination" ;;
  https://release.example/*) cp "$FIXTURE_ARCHIVE" "$destination" ;;
  *) echo "unsafe request reached wget" >&2; exit 90 ;;
esac
`

type bootstrapFixture struct {
	dir, bin, script, manifest string
	env                        []string
}

func bootstrapSetup(t *testing.T, downloader string, missing bool) bootstrapFixture {
	t.Helper()
	if runtime.GOOS != "linux" {
		t.Skip("POSIX bootstrap is tested in Linux")
	}
	f := bootstrapFixture{dir: testDirectory(t)}
	f.bin = filepath.Join(f.dir, "bin")
	if err := os.MkdirAll(f.bin, 0755); err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(filepath.Join("..", "..", "deploy", "install.sh"))
	if err != nil {
		t.Fatal(err)
	}
	f.script = filepath.Join(f.dir, "install.sh")
	writeTest(t, f.script, original)
	for _, name := range []string{"uname", "mkdir", "rm", "chmod", "cp", "ln", "tar", "gzip", "sha256sum", "awk"} {
		if missing && (name == "tar" || name == "sha256sum" || name == "awk") {
			continue
		}
		p, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(p, filepath.Join(f.bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	f.env = append(os.Environ(), "PATH="+f.bin, "SUBFLOW_VERSION=subflow-v1.0.0")
	writeExecutable := func(name, source string) {
		p := filepath.Join(f.bin, name)
		writeTest(t, p, []byte(source))
		if err := os.Chmod(p, 0755); err != nil {
			t.Fatal(err)
		}
	}
	writeExecutable("id", "#!/bin/sh\nprintf '0\\n'\n")
	switch downloader {
	case "curl":
		writeExecutable("curl", curlBootstrapStub)
	case "wget":
		writeExecutable("wget", wgetBootstrapStub)
	case "apt":
		helper := filepath.Join(f.dir, "curl-helper")
		writeTest(t, helper, []byte(curlBootstrapStub))
		if err := os.Chmod(helper, 0755); err != nil {
			t.Fatal(err)
		}
		writeExecutable("apt-get", `#!/bin/sh
printf '%s\n' "$*" >> "$APT_LOG"
if [ "${APT_FAIL:-0}" = 1 ]; then exit 42; fi
if [ "$1" = install ]; then
  cp "$CURL_HELPER" "$TEST_BIN/curl"
  ln -s "$REAL_TAR" "$TEST_BIN/tar"
  ln -s "$REAL_SHA" "$TEST_BIN/sha256sum"
  ln -s "$REAL_AWK" "$TEST_BIN/awk"
fi
`)
		f.env = append(f.env, "CURL_HELPER="+helper, "TEST_BIN="+f.bin, "APT_LOG="+filepath.Join(f.dir, "apt.log"))
		for key, name := range map[string]string{"REAL_TAR": "tar", "REAL_SHA": "sha256sum", "REAL_AWK": "awk"} {
			p, err := exec.LookPath(name)
			if err != nil {
				t.Fatal(err)
			}
			f.env = append(f.env, key+"="+p)
		}
	}
	installer := []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$INSTALL_LOG\"\nexit \"${INSTALL_EXIT:-0}\"\n")
	archive := archiveFixture(t, map[string][]byte{"subflow": installer})
	archivePath := filepath.Join(f.dir, "release.tar.gz")
	writeTest(t, archivePath, archive)
	sum := sha256.Sum256(archive)
	f.manifest = filepath.Join(f.dir, "checksums.txt")
	writeTest(t, f.manifest, []byte(fmt.Sprintf("%x  subflow-linux-%s.tar.gz\n", sum, runtime.GOARCH)))
	f.env = append(f.env, "FIXTURE_ARCHIVE="+archivePath, "FIXTURE_MANIFEST="+f.manifest, "INSTALL_LOG="+filepath.Join(f.dir, "installer.log"), "REQUEST_LOG="+filepath.Join(f.dir, "requests.log"))
	return f
}

func (f bootstrapFixture) run(t *testing.T, input string, args ...string) (int, string) {
	t.Helper()
	cmd := exec.Command("/bin/sh", append([]string{f.script}, args...)...)
	cmd.Dir, cmd.Env = f.dir, f.env
	cmd.Stdin = strings.NewReader(input)
	out, err := cmd.CombinedOutput()
	code := 0
	if err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			code = exit.ExitCode()
		} else {
			t.Fatal(err)
		}
	}
	matches, err := filepath.Glob(filepath.Join(f.dir, ".subflow-bootstrap.*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Fatalf("bootstrap did not clean owned staging directory: %v\n%s", matches, out)
	}
	return code, string(out)
}

func TestBootstrapCleansSuccessAndPreservesInstallerExit(t *testing.T) {
	for _, want := range []int{0, 7} {
		t.Run(fmt.Sprint(want), func(t *testing.T) {
			f := bootstrapSetup(t, "curl", false)
			f.env = append(f.env, fmt.Sprintf("INSTALL_EXIT=%d", want))
			code, out := f.run(t, "", "--yes", "--set", "SUBFLOW_PUBLIC_IP=example.com")
			if code != want {
				t.Fatalf("exit %d, want %d: %s", code, want, out)
			}
			b, err := os.ReadFile(filepath.Join(f.dir, "installer.log"))
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(b), "install --assets ") || !strings.Contains(string(b), "--set SUBFLOW_PUBLIC_IP=example.com") {
				t.Fatalf("arguments lost: %s", b)
			}
		})
	}
}

func TestBootstrapCleansDownloadAndChecksumFailures(t *testing.T) {
	for _, failure := range []string{"download", "checksum"} {
		t.Run(failure, func(t *testing.T) {
			f := bootstrapSetup(t, "curl", false)
			if failure == "download" {
				f.env = append(f.env, "DOWNLOAD_FAIL=18")
			} else {
				writeTest(t, f.manifest, []byte(strings.Repeat("0", 64)+" subflow-linux-"+runtime.GOARCH+".tar.gz\n"))
			}
			code, out := f.run(t, "", "--yes")
			if code == 0 {
				t.Fatalf("failure accepted: %s", out)
			}
			if failure == "download" && code != 18 {
				t.Fatalf("download status lost: %d", code)
			}
			if fileExists(filepath.Join(f.dir, "installer.log")) {
				t.Fatal("installer ran without verified download")
			}
		})
	}
}

func TestBootstrapWgetValidatesEveryRedirect(t *testing.T) {
	for _, insecure := range []bool{false, true} {
		t.Run(fmt.Sprint(insecure), func(t *testing.T) {
			f := bootstrapSetup(t, "wget", false)
			if insecure {
				f.env = append(f.env, "INSECURE_REDIRECT=1")
			}
			code, out := f.run(t, "", "--yes")
			if insecure && code == 0 {
				t.Fatal("HTTPS downgrade accepted")
			}
			if !insecure && code != 0 {
				t.Fatalf("HTTPS fallback failed: %s", out)
			}
			b, err := os.ReadFile(filepath.Join(f.dir, "requests.log"))
			if err != nil {
				t.Fatal(err)
			}
			for _, url := range strings.Fields(string(b)) {
				if !strings.HasPrefix(url, "https://") {
					t.Fatalf("unsafe URL requested: %s", url)
				}
			}
		})
	}
}

func TestBootstrapDebianDependencyConsentAndErrors(t *testing.T) {
	if _, err := os.Stat("/etc/debian_version"); err != nil {
		t.Skip("Debian-family dependency bootstrap contract")
	}

	for _, scenario := range []string{"approved", "declined", "apt-failure"} {
		t.Run(scenario, func(t *testing.T) {
			f := bootstrapSetup(t, "apt", true)
			var args []string
			input := "no\n"
			if scenario != "declined" {
				args = []string{"--yes"}
			}
			if scenario == "apt-failure" {
				f.env = append(f.env, "APT_FAIL=1")
			}
			code, out := f.run(t, input, args...)
			switch scenario {
			case "approved":
				if code != 0 {
					t.Fatalf("dependency installation failed: %s", out)
				}
				b, _ := os.ReadFile(filepath.Join(f.dir, "apt.log"))
				if !strings.Contains(string(b), "install --yes --no-install-recommends tar coreutils mawk curl") {
					t.Fatalf("unexpected packages: %s", b)
				}
			case "declined":
				if code == 0 || fileExists(filepath.Join(f.dir, "apt.log")) {
					t.Fatalf("declined consent ignored: %s", out)
				}
			case "apt-failure":
				if code == 0 || !strings.Contains(out, "apt-get update") {
					t.Fatalf("apt failure not surfaced: %s", out)
				}
				if fileExists(filepath.Join(f.dir, "installer.log")) {
					t.Fatal("installer ran after apt failure")
				}
			}
		})
	}
}
