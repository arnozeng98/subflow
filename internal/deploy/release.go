package deploy

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
)

const downloadLimit = 256 << 20

var releaseTag = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$`)

func (a *app) get(ctx context.Context, target string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "subflow-native-installer")
	resp, err := a.o.HTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download %s: HTTP %d", req.URL.Path, resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, errors.New("download exceeds size limit")
	}
	return b, nil
}

type githubRelease struct {
	Tag        string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
	Assets     []struct {
		Name string `json:"name"`
	} `json:"assets"`
}

func (a *app) latestTag(ctx context.Context, product string) (string, error) {
	asset := product + "-linux-" + a.o.Arch + ".tar.gz"
	matches := func(r githubRelease) bool {
		if !releaseTag.MatchString(r.Tag) || r.Draft || r.Prerelease {
			return false
		}
		if product == "subflow" && !strings.HasPrefix(r.Tag, "subflow-v") {
			return false
		}
		if product == "sing-box" && !strings.HasPrefix(r.Tag, "v") {
			return false
		}
		for _, entry := range r.Assets {
			if entry.Name == asset {
				return true
			}
		}
		return false
	}
	if product == "subflow" {
		b, err := a.get(ctx, a.o.ReleaseAPI+"/latest", 2<<20)
		if err != nil {
			return "", err
		}
		var r githubRelease
		if err = json.Unmarshal(b, &r); err != nil {
			return "", err
		}
		if !matches(r) {
			return "", errors.New("latest release is not a compatible subflow-v application release")
		}
		return r.Tag, nil
	}
	// Kernel releases are intentionally not marked GitHub "latest".
	for page := 1; page <= 10; page++ {
		b, err := a.get(ctx, fmt.Sprintf("%s?per_page=100&page=%d", a.o.ReleaseAPI, page), 8<<20)
		if err != nil {
			return "", err
		}
		var releases []githubRelease
		if err = json.Unmarshal(b, &releases); err != nil {
			return "", err
		}
		for _, r := range releases {
			if matches(r) {
				return r.Tag, nil
			}
		}
		if len(releases) < 100 {
			break
		}
	}
	return "", errors.New("no stable sing-box release with a matching architecture asset found; supply --version")
}

func (a *app) release(ctx context.Context, product, version string) (map[string][]byte, string, error) {
	if a.o.Arch != "amd64" && a.o.Arch != "arm64" {
		return nil, "", fmt.Errorf("unsupported Linux architecture %q", a.o.Arch)
	}
	if version == "latest" {
		var err error
		version, err = a.latestTag(ctx, product)
		if err != nil {
			return nil, "", err
		}
	}
	if !releaseTag.MatchString(version) {
		return nil, "", errors.New("invalid release tag")
	}
	if product == "subflow" && !strings.HasPrefix(version, "subflow-v") {
		return nil, "", errors.New("application releases must use subflow-v* tags")
	}
	name := product + "-linux-" + a.o.Arch + ".tar.gz"
	base := strings.TrimRight(a.o.ReleaseBase, "/") + "/" + url.PathEscape(version) + "/"
	manifest, err := a.get(ctx, base+"sha256sum.txt", 2<<20)
	if err != nil {
		return nil, "", fmt.Errorf("mandatory checksum manifest: %w", err)
	}
	expected, err := checksum(manifest, name)
	if err != nil {
		return nil, "", err
	}
	data, err := a.get(ctx, base+name, downloadLimit)
	if err != nil {
		return nil, "", err
	}
	actual := sha256.Sum256(data)
	if !bytes.Equal(expected, actual[:]) {
		return nil, "", fmt.Errorf("SHA-256 mismatch for %s", name)
	}
	files, err := extractArchive(data)
	if err != nil {
		return nil, "", err
	}
	if len(files[product]) == 0 {
		return nil, "", fmt.Errorf("release missing root executable %s", product)
	}
	return files, version, nil
}

func checksum(manifest []byte, name string) ([]byte, error) {
	var result []byte
	for _, line := range strings.Split(string(manifest), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		filename := strings.TrimPrefix(f[1], "*")
		if filename != name && filename != "./"+name {
			continue
		}
		if result != nil {
			return nil, fmt.Errorf("duplicate checksum for %s", name)
		}
		b, err := hex.DecodeString(f[0])
		if err != nil || len(b) != sha256.Size {
			return nil, fmt.Errorf("invalid SHA-256 for %s", name)
		}
		result = b
	}
	if result == nil {
		return nil, fmt.Errorf("checksum manifest has no entry for %s", name)
	}
	return result, nil
}

func extractArchive(data []byte) (map[string][]byte, error) {
	gz, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer gz.Close()
	r := tar.NewReader(gz)
	files := map[string][]byte{}
	var total int64
	for {
		h, err := r.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		name := strings.TrimPrefix(h.Name, "./")
		clean := path.Clean(name)
		if clean == "." && h.Typeflag == tar.TypeDir {
			continue
		}
		if strings.ContainsAny(name, "\\:\x00") || strings.HasPrefix(name, "/") || clean == ".." || strings.HasPrefix(clean, "../") || clean != strings.TrimSuffix(name, "/") {
			return nil, fmt.Errorf("unsafe archive path %q", h.Name)
		}
		if h.Typeflag == tar.TypeDir {
			continue
		}
		if h.Typeflag != tar.TypeReg {
			return nil, fmt.Errorf("unsupported archive entry %q (links/devices prohibited)", name)
		}
		total += h.Size
		if h.Size < 0 || total > 512<<20 || len(files) > 10000 {
			return nil, errors.New("release archive exceeds extraction limit")
		}
		if _, ok := files[clean]; ok {
			return nil, fmt.Errorf("duplicate archive path %q", clean)
		}
		b, err := io.ReadAll(io.LimitReader(r, h.Size+1))
		if err != nil {
			return nil, err
		}
		if int64(len(b)) != h.Size {
			return nil, errors.New("truncated archive")
		}
		files[clean] = b
	}
	return files, nil
}
