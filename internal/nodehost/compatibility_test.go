package nodehost

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/arnozeng98/subflow/internal/state"
)

func TestExistingConfigAndPublicUserFieldsImport(t *testing.T) {
	h := testHost(t)
	h.opts.Config.BusinessTimezone = "UTC"
	h.opts.Now = func() time.Time { return time.Date(2026, time.October, 31, 12, 0, 0, 0, time.UTC) }
	ordinary(h, "alice")
	for i, protocol := range Protocols {
		addNode(t, h, protocol, protocol, 25000+i)
	}
	usersBefore := map[string][]byte{}
	tlsBefore := map[string][]byte{}
	for _, raw := range list(h.config["inbounds"]) {
		in := object(raw)
		tag := text(in["tag"])
		for _, entry := range list(in["users"]) {
			credential := object(entry)
			key := "name"
			if text(in["type"]) == "socks" {
				key = "username"
			}
			if strings.HasSuffix(text(credential[key]), "@admin") {
				credential[key] = "administrator"
			} else {
				credential[key] = "legacy-profile@alice"
			}
		}
		if text(in["type"]) == "socks" {
			alias := clone(object(list(in["users"])[1]))
			alias["username"] = "alternate-login@alice"
			in["users"] = append(list(in["users"]), alias)
		}
		usersBefore[tag], _ = json.Marshal(in["users"])
		tlsBefore[tag], _ = json.Marshal(in["tls"])
	}
	if err := state.WriteJSON(h.opts.Config.ConfigPath, h.config); err != nil {
		t.Fatal(err)
	}
	legacy := Object{"users": Object{
		"admin": Object{"enabled": true, "quota_gb": 0, "used_up_bytes": 999, "used_down_bytes": 999, "expire_at": "0"},
		"alice": Object{"enabled": true, "quota_gb": "1.5", "used_up_bytes": "100", "used_down_bytes": 50, "manual_added_bytes": "0", "reset_day": "32", "last_reset_period": "2026-10-31", "expire_at": "2026-12-31"},
	}}
	if err := state.WriteJSON(h.opts.Config.UserDBPath, legacy); err != nil {
		t.Fatal(err)
	}
	if err := h.run(context.Background(), []string{"config", "init"}); err != nil {
		t.Fatal(err)
	}
	for _, raw := range list(h.config["inbounds"]) {
		in := object(raw)
		tag := text(in["tag"])
		users, _ := json.Marshal(in["users"])
		tls, _ := json.Marshal(in["tls"])
		if !bytes.Equal(usersBefore[tag], users) || !bytes.Equal(tlsBefore[tag], tls) {
			t.Fatalf("existing credentials/TLS changed for %s", tag)
		}
	}
	u := h.db.Users["alice"]
	if u.QuotaGB != 1.5 || u.QuotaBytes != 1610612736 || u.Up != 100 || u.Down != 50 || u.ResetDay != 32 || u.ExpireAt != "2026-12-31" || u.Expires != time.Date(2027, time.January, 1, 0, 0, 0, 0, time.UTC).Unix() {
		t.Fatalf("public user fields not imported %+v", u)
	}
	if h.db.Users["admin"].Up != 0 || h.db.Users["admin"].Down != 0 {
		t.Fatal("import attributed usage to admin")
	}
	if len(u.CredentialAliases["socks"]) != 1 {
		t.Fatal("additional imported credential lost")
	}
	var persisted struct {
		Users map[string]map[string]json.RawMessage `json:"users"`
	}
	if err := state.ReadJSON(h.opts.Config.UserDBPath, &persisted); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"enabled", "quota_gb", "used_up_bytes", "used_down_bytes", "expire_at", "reset_day"} {
		if persisted.Users["alice"][key] == nil {
			t.Fatal("API compatibility field missing", key)
		}
	}
	if string(persisted.Users["alice"]["quota_gb"]) != "1.5" {
		t.Fatal("fractional quota truncated")
	}
	h.opts.Stats = func(context.Context, string) ([]Stat, error) {
		return []Stat{{"user>>>legacy-profile@alice>>>traffic>>>uplink", 20}, {"user>>>alternate-login@alice>>>traffic>>>downlink", 10}, {"user>>>administrator>>>traffic>>>uplink", 999}}, nil
	}
	if err := h.sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	if h.db.Users["alice"].Up != 120 || h.db.Users["alice"].Down != 60 || h.db.Users["admin"].Up != 0 {
		t.Fatal("imported identity counters misattributed")
	}
}

func TestPublicExpiryAndQuotaScalarCompatibility(t *testing.T) {
	for _, test := range []struct {
		expiry string
		want   int64
	}{
		{`"0"`, 0}, {`0`, 0}, {`"1800000000"`, 1800000000}, {`1800000000`, 1800000000},
		{`"2026-12-31T12:30:00Z"`, time.Date(2026, time.December, 31, 12, 30, 0, 0, time.UTC).Unix()},
	} {
		var u User
		if err := json.Unmarshal([]byte(fmt.Sprintf(`{"enabled":true,"quota_gb":0.5,"expire_at":%s}`, test.expiry)), &u); err != nil {
			t.Fatal(err)
		}
		if err := u.decodeExpiry(time.UTC); err != nil {
			t.Fatal(err)
		}
		if u.Expires != test.want || u.QuotaBytes != 536870912 {
			t.Fatalf("scalar compatibility mismatch %+v", u)
		}
	}
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "edge", 1080)
	u := h.db.Users["alice"]
	u.QuotaBytes = 100
	u.Up = 90
	u.Manual = 20
	if h.active("alice", "edge") {
		t.Fatal("legacy additive manual usage ignored")
	}
	u.Manual = -20
	if !h.active("alice", "edge") {
		t.Fatal("legacy negative manual adjustment ignored")
	}
}
