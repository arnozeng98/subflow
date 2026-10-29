package deploy

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestBootstrapNeverAdoptsAnExistingStagingDirectory(t *testing.T) {
	f := bootstrapSetup(t, "curl", false)
	realMkdir, err := exec.LookPath("mkdir")
	if err != nil {
		t.Fatal(err)
	}
	stub := filepath.Join(f.bin, "mkdir")
	if err = os.Remove(stub); err != nil {
		t.Fatal(err)
	}
	writeTest(t, stub, []byte(`#!/bin/sh
"$REAL_MKDIR" "$1"
printf 'existing user data\n' > "$1/user-marker"
exit 73
`))
	if err = os.Chmod(stub, 0755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("/bin/sh", f.script, "--yes")
	cmd.Dir = f.dir
	cmd.Env = append(f.env, "REAL_MKDIR="+realMkdir)
	out, err := cmd.CombinedOutput()
	if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 73 {
		t.Fatalf("expected exclusive-mkdir failure: %v %s", err, out)
	}
	dirs, err := filepath.Glob(filepath.Join(f.dir, ".subflow-bootstrap.*"))
	if err != nil || len(dirs) != 1 {
		t.Fatalf("existing directory was removed: %v %v", dirs, err)
	}
	data, err := os.ReadFile(filepath.Join(dirs[0], "user-marker"))
	if err != nil || string(data) != "existing user data\n" {
		t.Fatalf("existing contents changed: %q %v", data, err)
	}
}
