package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func main() {
	version := flag.String("version", "dev", "release version")
	output := flag.String("out", "dist", "artifact output directory")
	flag.Parse()
	if err := build(*version, *output); err != nil {
		fmt.Fprintln(os.Stderr, "release:", err)
		os.Exit(1)
	}
}

func build(version, output string) error {
	if strings.ContainsAny(version, "'\" \r\n\t") || version == "" {
		return errors.New("version must be a nonempty identifier")
	}
	if err := os.MkdirAll(output, 0755); err != nil {
		return err
	}
	sourceFiles := []string{
		"package.json", "package-lock.json", "tsconfig.json", "LICENSE", "README.md", "THIRD_PARTY.md", "SECURITY.md", "go.mod", "go.sum",
		filepath.Join("cloudflare", "dist", "_worker.js"),
		filepath.Join("cloudflare", "dist", "_routes.json"),
		filepath.Join("cloudflare", "dist", "404.html"),
		filepath.Join("cloudflare", "dist", "index.html"),
		filepath.Join("cloudflare", "dist", "admin.js"),
		filepath.Join("cloudflare", "dist", "admin.css"),
		filepath.Join("contracts", "raw.schema.json"),
		filepath.Join("contracts", "fixtures", "raw-alice.json"),
		filepath.Join("deploy", "install.sh"),
	}
	err := filepath.WalkDir("cloudflare", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if entry.Name() == "node_modules" || entry.Name() == ".wrangler" || entry.Name() == "dist" {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing release symlink: %s", path)
		}
		ext := filepath.Ext(path)
		if ext == ".ts" || ext == ".txt" || ext == ".sql" || ext == ".html" || ext == ".css" || ext == ".json" || ext == ".md" || filepath.Base(path) == "wrangler.toml" {
			sourceFiles = append(sourceFiles, path)
		}
		return nil
	})
	if err != nil {
		return err
	}
	for _, dir := range []string{"cmd", "internal", "configs", "docs"} {
		if err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() && strings.HasPrefix(entry.Name(), ".") {
				return filepath.SkipDir
			}
			if entry.Type()&os.ModeSymlink != 0 {
				return fmt.Errorf("refusing release source symlink: %s", path)
			}
			if !entry.IsDir() && (filepath.Ext(path) == ".go" || filepath.Ext(path) == ".md" || filepath.Ext(path) == ".json") {
				sourceFiles = append(sourceFiles, path)
			}
			return nil
		}); err != nil {
			return err
		}
	}
	licenses, err := moduleLicenses()
	if err != nil {
		return err
	}
	sort.Strings(sourceFiles)
	var checksums strings.Builder
	for _, arch := range []string{"amd64", "arm64"} {
		binary, err := os.CreateTemp(output, ".subflow-"+arch+"-*")
		if err != nil {
			return err
		}
		binaryPath := binary.Name()
		if err := binary.Close(); err != nil {
			return err
		}
		err = func() (err error) {
			defer func() { err = errors.Join(err, os.Remove(binaryPath)) }()
			cmd := exec.Command("go", "build", "-trimpath", "-ldflags", "-s -w -X main.version="+version, "-o", binaryPath, "./cmd/subflow")
			cmd.Env = buildEnv(arch)
			cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
			if err := cmd.Run(); err != nil {
				return fmt.Errorf("build linux/%s: %w", arch, err)
			}
			name := "subflow-linux-" + arch + ".tar.gz"
			target := filepath.Join(output, name)
			if err := archive(target, binaryPath, sourceFiles, licenses); err != nil {
				return err
			}
			digest, err := checksum(target)
			if err != nil {
				return err
			}
			fmt.Fprintf(&checksums, "%s  %s\n", digest, name)
			return nil
		}()
		if err != nil {
			return err
		}
	}
	return os.WriteFile(filepath.Join(output, "sha256sum.txt"), []byte(checksums.String()), 0644)
}

func buildEnv(arch string) []string {
	env := make([]string, 0, len(os.Environ())+3)
	for _, assignment := range os.Environ() {
		key, _, _ := strings.Cut(assignment, "=")
		switch strings.ToUpper(key) {
		case "GOOS", "GOARCH", "CGO_ENABLED":
		default:
			env = append(env, assignment)
		}
	}
	return append(env, "GOOS=linux", "GOARCH="+arch, "CGO_ENABLED=0")
}

func archive(target, binary string, sourceFiles []string, extraFiles ...map[string]string) (err error) {
	f, err := os.Create(target)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, f.Close()) }()
	gzipWriter := gzip.NewWriter(f)
	defer func() { err = errors.Join(err, gzipWriter.Close()) }()
	writer := tar.NewWriter(gzipWriter)
	defer func() { err = errors.Join(err, writer.Close()) }()
	add := func(source, name string, mode int64) error {
		input, err := os.Open(source)
		if err != nil {
			return err
		}
		defer input.Close()
		info, err := input.Stat()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("not a regular release file: %s", source)
		}
		header := &tar.Header{Name: name, Mode: mode, Size: info.Size(), ModTime: time.Unix(0, 0)}
		if err := writer.WriteHeader(header); err != nil {
			return err
		}
		_, err = io.Copy(writer, input)
		return err
	}
	if err := add(binary, "subflow", 0755); err != nil {
		return err
	}
	for _, path := range sourceFiles {
		if err := add(path, filepath.ToSlash(path), 0644); err != nil {
			return err
		}
	}
	for _, files := range extraFiles {
		names := make([]string, 0, len(files))
		for name := range files {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			if err := add(files[name], name, 0644); err != nil {
				return err
			}
		}
	}
	return nil
}

func moduleLicenses() (map[string]string, error) {
	b, err := exec.Command("go", "list", "-m", "-json", "all").Output()
	if err != nil {
		return nil, fmt.Errorf("enumerate dependency licenses: %w", err)
	}
	result := map[string]string{}
	decoder := json.NewDecoder(strings.NewReader(string(b)))
	for {
		var module struct {
			Path, Dir string
			Main      bool
		}
		if err := decoder.Decode(&module); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			return nil, err
		}
		if module.Main {
			continue
		}
		if module.Dir == "" {
			return nil, fmt.Errorf("module source not downloaded: %s; run go mod download all", module.Path)
		}
		files, err := licenseFiles(module.Dir)
		if err != nil {
			return nil, fmt.Errorf("module license missing for %s: %w", module.Path, err)
		}
		for name, path := range files {
			result["licenses/"+module.Path+"/"+name] = path
		}
	}
	goroot, err := exec.Command("go", "env", "GOROOT").Output()
	if err != nil {
		return nil, err
	}
	result["licenses/Go/LICENSE"] = filepath.Join(strings.TrimSpace(string(goroot)), "LICENSE")
	return result, nil
}

func licenseFiles(dir string) (map[string]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	result := map[string]string{}
	hasLicense := false
	for _, entry := range entries {
		if !entry.Type().IsRegular() {
			continue
		}
		name := strings.ToUpper(entry.Name())
		for _, prefix := range []string{"LICENSE", "LICENCE", "COPYING", "NOTICE"} {
			if name == prefix || strings.HasPrefix(name, prefix+".") || strings.HasPrefix(name, prefix+"-") {
				result[entry.Name()] = filepath.Join(dir, entry.Name())
				hasLicense = hasLicense || prefix != "NOTICE"
				break
			}
		}
	}
	if !hasLicense {
		return nil, errors.New("no recognized license file")
	}
	return result, nil
}

func checksum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
