package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"reflect"
	"testing"
)

func TestCommandRouting(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want []string
		fail bool
	}{
		{"sf", nil, []string{"deploy:menu"}, false},
		{"s", nil, []string{"manager:menu"}, false},
		{"subflow", []string{"manager", "user", "list"}, []string{"manager:user", "list"}, false},
		{"subflow", []string{"users", "list"}, []string{"manager:user", "list"}, false},
		{"subflow", []string{"agent", "sync"}, []string{"manager:agent", "sync"}, false},
		{"subflow", []string{"system", "prepare-restart"}, []string{"manager:system", "prepare-restart"}, false},
		{"subflow", []string{"service", "restart"}, []string{"manager:service", "restart"}, false},
		{"subflow", []string{"sync"}, []string{"manager:sync"}, false},
		{"subflow", []string{"--periodic-sync"}, []string{"manager:sync"}, false},
		{"subflow", []string{"--daily-maintenance"}, []string{"manager:maintenance", "deploy:maintenance"}, false},
		{"subflow", []string{"--user-watch"}, nil, false},
		{"subflow", []string{"serve"}, []string{"serve:"}, false},
		{"subflow", []string{"nonsense"}, nil, true},
	} {
		t.Run(tc.name+":"+join(tc.args), func(t *testing.T) {
			var calls []string
			runner := func(name string) Runner {
				return func(_ context.Context, args []string, _ io.Reader, _, _ io.Writer) error {
					if len(args) == 0 {
						calls = append(calls, name+":")
					} else {
						calls = append(calls, name+":"+args[0])
						calls = append(calls, args[1:]...)
					}
					return nil
				}
			}
			app := App{
				Manager: runner("manager"),
				Deploy:  runner("deploy"), Serve: runner("serve"),
				In: bytes.NewReader(nil), Out: io.Discard, Err: io.Discard,
			}
			err := app.Run(t.Context(), tc.name, tc.args)
			if (err != nil) != tc.fail || !reflect.DeepEqual(calls, tc.want) {
				t.Fatalf("calls=%v want=%v err=%v", calls, tc.want, err)
			}
		})
	}
}

func TestSyncPropagatesManagerFailure(t *testing.T) {
	failure := errors.New("sync failed")
	app := App{
		Manager: func(context.Context, []string, io.Reader, io.Writer, io.Writer) error {
			return failure
		},
	}
	if err := app.Run(t.Context(), "subflow", []string{"sync"}); !errors.Is(err, failure) {
		t.Fatalf("sync failure was not propagated: %v", err)
	}
}

func join(args []string) string {
	var buf bytes.Buffer
	for _, s := range args {
		buf.WriteString(s + " ")
	}
	return buf.String()
}
