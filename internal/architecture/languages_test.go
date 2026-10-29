package architecture

import (
	"io/fs"
	"path/filepath"
	"testing"
)

func TestAuthoredRuntimeLanguages(t *testing.T) {
	root := filepath.Join("..", "..")
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			switch entry.Name() {
			case ".git", "node_modules", "dist", ".wrangler":
				return filepath.SkipDir
			}
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		switch filepath.Ext(path) {
		case ".py", ".js", ".mjs", ".cjs":
			t.Errorf("legacy authored runtime source remains: %s", relative)
		case ".sh":
			if relative != filepath.Join("deploy", "install.sh") {
				t.Errorf("Shell is reserved for the minimal bootstrap: %s", relative)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
