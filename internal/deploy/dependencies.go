package deploy

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
)

func (a *app) lookup(name string) (string, error) {
	if a.o.LookPath != nil {
		return a.o.LookPath(name)
	}
	return exec.LookPath(name)
}

func (a *app) ensureHostDependencies(ctx context.Context, yes, chrony bool) error {
	var packages []string
	if _, err := a.lookup("systemctl"); err != nil {
		packages = append(packages, "systemd")
	}
	if !fileExists(a.path("/etc/ssl/certs/ca-certificates.crt")) {
		packages = append(packages, "ca-certificates")
	}
	if chrony {
		if _, err := a.lookup("chronyc"); err != nil {
			packages = append(packages, "chrony")
		}
	}
	if len(packages) == 0 {
		return nil
	}
	return a.installDebianPackages(ctx, yes, packages)
}

func (a *app) installDebianPackages(ctx context.Context, yes bool, packages []string) error {
	b, err := os.ReadFile(a.path("/etc/os-release"))
	if err != nil {
		return fmt.Errorf("missing dependencies %v; cannot identify distribution: %w", packages, err)
	}
	distro := map[string]string{}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(line, "=")
		if ok {
			distro[k] = strings.Trim(v, "\"'")
		}
	}
	if distro["ID"] != "debian" && !strings.Contains(distro["ID_LIKE"], "debian") {
		return fmt.Errorf("missing dependencies %v; automatic packages support Debian/apt systems only (detected %s %s)", packages, distro["ID"], distro["VERSION_ID"])
	}
	if _, err = a.lookup("apt-get"); err != nil {
		return fmt.Errorf("missing dependencies %v and apt-get is unavailable: %w", packages, err)
	}
	if err = a.confirm(fmt.Sprintf("Install Debian %s packages: %s?", distro["VERSION_ID"], strings.Join(packages, ", ")), yes); err != nil {
		return err
	}
	env := append(os.Environ(), "DEBIAN_FRONTEND=noninteractive")
	for _, args := range [][]string{{"update"}, append([]string{"install", "--yes", "--no-install-recommends"}, packages...)} {
		if _, err = a.o.Execute(ctx, Command{Name: "apt-get", Args: args, Env: env, Stdout: a.out, Stderr: a.errOut}); err != nil {
			return fmt.Errorf("Debian dependency installation (apt-get %s) failed: %w", args[0], err)
		}
	}
	for _, pkg := range packages {
		command := map[string]string{"systemd": "systemctl", "chrony": "chronyc"}[pkg]
		if command != "" {
			if _, err = a.lookup(command); err != nil {
				return fmt.Errorf("apt-get completed but required command %s is unavailable: %w", command, err)
			}
		}
		if pkg == "ca-certificates" && !fileExists(a.path("/etc/ssl/certs/ca-certificates.crt")) {
			return errors.New("apt-get completed but the system CA certificate bundle is missing")
		}
	}
	return nil
}

func nodeMajor(version []byte) int {
	raw := strings.TrimPrefix(strings.TrimSpace(string(version)), "v")
	first, _, _ := strings.Cut(raw, ".")
	n, _ := strconv.Atoi(first)
	return n
}

func (a *app) ensureNode(ctx context.Context, yes bool) error {
	if node, err := a.lookup("node"); err == nil {
		b, err := a.o.Execute(ctx, Command{Name: node, Args: []string{"--version"}})
		if err == nil && nodeMajor(b) >= 24 {
			if npm, err := a.lookup("npm"); err == nil {
				if _, err = a.o.Execute(ctx, Command{Name: npm, Args: []string{"--version"}}); err == nil {
					a.nodePath = node
					return nil
				}
			}
		}
	}
	// Reuse our versioned runtime without replacing the machine's existing Node.
	stamp := a.path("/opt/subflow/node/current-version")
	if b, err := os.ReadFile(stamp); err == nil {
		version := strings.TrimSpace(string(b))
		if strings.HasPrefix(version, "v24.") && releaseTag.MatchString(version) {
			node := a.path("/opt/subflow/node/" + version + "/bin/node")
			npm := a.path("/opt/subflow/node/" + version + "/lib/node_modules/npm/bin/npm-cli.js")
			if fileExists(npm) {
				if b, err := a.o.Execute(ctx, Command{Name: node, Args: []string{"--version"}}); err == nil && nodeMajor(b) == 24 {
					a.nodePath, a.npmCLI = node, npm
					return nil
				}
			}
		}
	}
	if err := a.confirm("Cloudflare requires Node.js 24+ and npm. Download and SHA-256-verify the official Node 24 runtime under /opt/subflow/node (without replacing system Node)?", yes); err != nil {
		return err
	}
	index := a.o.NodeIndex
	if index == "" {
		index = "https://nodejs.org/dist/index.json"
	}
	base := a.o.NodeBase
	if base == "" {
		base = "https://nodejs.org/dist"
	}
	b, err := a.get(ctx, index, 8<<20)
	if err != nil {
		return fmt.Errorf("Node release index: %w", err)
	}
	var releases []struct {
		Version string `json:"version"`
	}
	if err = json.Unmarshal(b, &releases); err != nil {
		return err
	}
	version := ""
	for _, release := range releases {
		if strings.HasPrefix(release.Version, "v24.") && releaseTag.MatchString(release.Version) {
			version = release.Version
			break
		}
	}
	if version == "" {
		return errors.New("no official Node 24 release found")
	}
	arch := map[string]string{"amd64": "x64", "arm64": "arm64"}[a.o.Arch]
	if arch == "" {
		return errors.New("Node runtime supports Linux amd64/arm64")
	}
	name := "node-" + version + "-linux-" + arch + ".tar.gz"
	manifest, err := a.get(ctx, base+"/"+version+"/SHASUMS256.txt", 2<<20)
	if err != nil {
		return fmt.Errorf("mandatory Node checksum manifest: %w", err)
	}
	expected, err := checksum(manifest, name)
	if err != nil {
		return err
	}
	data, err := a.get(ctx, base+"/"+version+"/"+name, downloadLimit)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	if !bytes.Equal(sum[:], expected) {
		return errors.New("Node runtime SHA-256 mismatch")
	}
	files, err := extractNode(data, strings.TrimSuffix(name, ".tar.gz"))
	if err != nil {
		return err
	}
	node := a.path("/opt/subflow/node/" + version + "/bin/node")
	npm := a.path("/opt/subflow/node/" + version + "/lib/node_modules/npm/bin/npm-cli.js")
	err = a.transaction(ctx, func(t *transaction) error {
		for _, name := range sortedKeys(files) {
			mode := os.FileMode(0644)
			if name == "bin/node" || strings.HasSuffix(name, "/npm-cli.js") || strings.HasSuffix(name, "/npx-cli.js") {
				mode = 0755
			}
			if err := t.write(a.path("/opt/subflow/node/"+version+"/"+name), files[name], mode); err != nil {
				return err
			}
		}
		if err := t.symlink(a.path("/opt/subflow/node/"+version+"/bin/npm"), "../lib/node_modules/npm/bin/npm-cli.js"); err != nil {
			return err
		}
		if _, exists := files["lib/node_modules/npm/bin/npx-cli.js"]; exists {
			if err := t.symlink(a.path("/opt/subflow/node/"+version+"/bin/npx"), "../lib/node_modules/npm/bin/npx-cli.js"); err != nil {
				return err
			}
		}
		b, err := a.o.Execute(ctx, Command{Name: node, Args: []string{"--version"}})
		if err != nil || nodeMajor(b) != 24 {
			return fmt.Errorf("downloaded Node 24 cannot run on this host: %w", errors.Join(err, errors.New("expected Node major version 24")))
		}
		if err := t.write(stamp, []byte(version+"\n"), 0644); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		return err
	}
	a.nodePath, a.npmCLI = node, npm
	return nil
}

func extractNode(data []byte, root string) (map[string][]byte, error) {
	gz, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	files := map[string][]byte{}
	var total int64
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if h.Typeflag == tar.TypeDir && strings.TrimSuffix(h.Name, "/") == root {
			continue
		}
		if !strings.HasPrefix(h.Name, root+"/") || strings.ContainsAny(h.Name, "\\:\x00") {
			return nil, errors.New("unsafe Node archive path")
		}
		name := strings.TrimPrefix(h.Name, root+"/")
		if h.Typeflag == tar.TypeDir {
			continue
		}
		if path.Clean(name) != name || name == ".." || strings.HasPrefix(name, "../") {
			return nil, errors.New("unsafe Node archive traversal")
		}
		if h.Typeflag == tar.TypeSymlink {
			// We execute npm-cli.js via node directly, not the archive's npm/npx symlinks.
			target := path.Clean(path.Join(path.Dir(name), h.Linkname))
			if strings.HasPrefix(h.Linkname, "/") || strings.HasPrefix(target, "../") || target == ".." {
				return nil, errors.New("unsafe Node archive symlink target")
			}
			if name == "bin/npm" || name == "bin/npx" || name == "bin/corepack" || strings.HasPrefix(name, "lib/node_modules/npm/") {
				continue
			}
			return nil, fmt.Errorf("unexpected Node archive symlink %s", name)
		}
		if h.Typeflag != tar.TypeReg {
			return nil, errors.New("unsupported Node archive entry")
		}
		total += h.Size
		if total > 512<<20 || h.Size < 0 {
			return nil, errors.New("Node archive exceeds extraction limit")
		}
		if name != "bin/node" && !strings.HasPrefix(name, "lib/node_modules/npm/") {
			continue
		}
		if _, exists := files[name]; exists {
			return nil, errors.New("duplicate Node archive path")
		}
		b, err := io.ReadAll(io.LimitReader(tr, h.Size+1))
		if err != nil {
			return nil, err
		}
		files[name] = b
	}
	if len(files["bin/node"]) == 0 || len(files["lib/node_modules/npm/bin/npm-cli.js"]) == 0 {
		return nil, errors.New("Node archive missing node or npm")
	}
	return files, nil
}

func (a *app) nodeEnvironment(token, account, work string) []string {
	env := cleanCloudflareEnv(token, account, work)
	if a.nodePath == "" {
		return env
	}
	for i, entry := range env {
		if strings.HasPrefix(entry, "PATH=") {
			env[i] = "PATH=" + filepath.Dir(a.nodePath) + string(os.PathListSeparator) + strings.TrimPrefix(entry, "PATH=")
			return env
		}
	}
	return append(env, "PATH="+filepath.Dir(a.nodePath))
}
