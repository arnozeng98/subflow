package deploy

import (
	"context"
	"io"
	"strings"
	"testing"
)

func TestMenuUsesNativeManagerCallback(t *testing.T) {
	previous := ManagerRun
	t.Cleanup(func() { ManagerRun = previous })
	called := false
	ManagerRun = func(_ context.Context, args []string, in io.Reader, out, errOut io.Writer) error {
		called = true
		if len(args) != 1 || args[0] != "menu" {
			t.Fatalf("manager arguments %v", args)
		}
		return nil
	}
	err := RunWithOptions(context.Background(), []string{"menu"}, strings.NewReader("9\n0\n"), io.Discard, io.Discard, Options{RootDir: testDirectory(t), Execute: func(context.Context, Command) ([]byte, error) {
		t.Fatal("callback unnecessarily spawned a process")
		return nil, nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	if !called {
		t.Fatal("manager callback not called")
	}
}
