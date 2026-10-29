package main

import (
	"archive/tar"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestArchiveContainsExecutable(t *testing.T) {
	dir := t.TempDir()
	binary := filepath.Join(dir, "binary")
	if err := os.WriteFile(binary, []byte("binary-fixture"), 0644); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "release.tar.gz")
	if err := archive(target, binary, nil); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(target)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	defer gz.Close()
	reader := tar.NewReader(gz)
	header, err := reader.Next()
	if err != nil || header.Name != "subflow" || header.Mode != 0755 {
		t.Fatalf("header=%+v, err=%v", header, err)
	}
	data, err := io.ReadAll(reader)
	if err != nil || string(data) != "binary-fixture" {
		t.Fatalf("data=%q err=%v", data, err)
	}
	if _, err := reader.Next(); err != io.EOF {
		t.Fatalf("unexpected archive entry: %v", err)
	}
}

func TestBuildEnvOverridesHostTargets(t *testing.T) {
	t.Setenv("GOOS", "windows")
	t.Setenv("GOARCH", "amd64")
	t.Setenv("CGO_ENABLED", "1")
	env := buildEnv("arm64")
	if !reflect.DeepEqual(env[len(env)-3:], []string{"GOOS=linux", "GOARCH=arm64", "CGO_ENABLED=0"}) {
		t.Fatal("incorrect target environment")
	}

}

func TestLicenseFilesPreserveNamesAndNotices(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"License", "LICENSE-MIT", "COPYING.txt", "NOTICE", "README.md"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := licenseFiles(dir)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{}
	for _, name := range []string{"License", "LICENSE-MIT", "COPYING.txt", "NOTICE"} {
		want[name] = filepath.Join(dir, name)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("licenses=%v; want=%v", got, want)
	}
	empty := t.TempDir()
	if err := os.WriteFile(filepath.Join(empty, "NOTICE"), []byte("notice only"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := licenseFiles(empty); err == nil {
		t.Fatal("notice without license accepted")
	}
}
