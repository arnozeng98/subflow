package settings

import (
	"strings"
	"testing"
)

func TestConfiguration(t *testing.T) {
	for _, tc := range []struct {
		name string
		env  map[string]string
		fail bool
	}{
		{"defaults", nil, false},
		{"custom", map[string]string{"SUBFLOW_LISTEN_PORT": "31000", "SUBFLOW_INCLUDE_DISABLED_USERS": "yes"}, false},
		{"invalid port", map[string]string{"SUBFLOW_LISTEN_PORT": "oops"}, true},
		{"zero port", map[string]string{"SUBFLOW_LISTEN_PORT": "0"}, true},
		{"invalid boolean", map[string]string{"SUBFLOW_INCLUDE_DISABLED_USERS": "maybe"}, true},
		{"invalid timezone", map[string]string{"SUBFLOW_BUSINESS_TIMEZONE": "not/a/timezone"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, err := FromLookup(func(k string) (string, bool) { v, ok := tc.env[k]; return v, ok })
			if (err != nil) != tc.fail {
				t.Fatalf("config=%+v err=%v", c, err)
			}
			if tc.name == "defaults" && (c.Address() != "127.0.0.1:28080" || c.ConfigPath != "/etc/sing-box/config.json") {
				t.Fatalf("incompatible defaults: %+v", c)
			}
			if tc.name == "custom" && (c.ListenPort != 31000 || !c.IncludeDisabledUsers) {
				t.Fatalf("overrides not applied: %+v", c)
			}
		})
	}
}

func TestReadEnv(t *testing.T) {
	values, err := ReadEnv(strings.NewReader("# comment\nKEY='literal $VALUE'\nTOKEN=a=b\nEMPTY=\n"))
	if err != nil || values["KEY"] != "literal $VALUE" || values["TOKEN"] != "a=b" {
		t.Fatalf("values=%v err=%v", values, err)
	}
	for _, input := range []string{"BROKEN", "A=1\nA=2", "A='unterminated", "1BAD=x", "A=x\x00y"} {
		if _, err := ReadEnv(strings.NewReader(input)); err == nil {
			t.Errorf("accepted invalid environment %q", input)
		}
	}
}
