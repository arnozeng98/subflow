package api

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestProjectionNeverForwardsServerSecrets(t *testing.T) {
	var inbound map[string]json.RawMessage
	err := json.Unmarshal([]byte(`{"type":"vless","tag":"n","listen":"127.0.0.1","listen_port":443,
		"password":"TOP-SECRET","tls":{"server_name":"example.test","key":["TLS-SECRET"],
		"key_path":"FILE-SECRET","acme":{"api_token":"ACME-SECRET"},
		"reality":{"enabled":true,"short_id":["abcd"],"private_key":"REALITY-SECRET","handshake":{"server":"HIDDEN"}}},
		"transport":{"type":"ws","path":"/ws","headers":{"Authorization":"HEADER-SECRET"}}}`), &inbound)
	if err != nil {
		t.Fatal(err)
	}

	projected, err := projectInbound(inbound)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(projected)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "SECRET") || strings.Contains(string(data), "127.0.0.1") ||
		strings.Contains(string(data), "HIDDEN") {
		t.Fatalf("projection leaked private fields: %s", data)
	}
	if !strings.Contains(string(data), "example.test") || !strings.Contains(string(data), "abcd") {
		t.Fatal("projection removed client fields")
	}
}

func TestDisabledProjectionUsesPermittedPersistedCredentials(t *testing.T) {
	c := fixture(t)
	record := `{"users":{"alice":{"enabled":false,"nodes":["reality-in","socks-in"],
			"quota_gb":3.5,"expire_at":"2030-01-01","reset_day":32,
			"credentials":{
				"reality-in":{"name":"original@alice","uuid":"persisted-uuid","private_key":"STORED-SECRET"},
				"socks-in":{"username":"original-login@alice","password":"persisted-password"},
				"untagged-users":{"username":"denied@alice","password":"DENIED-SECRET"}
			},
			"credential_aliases":{"reality-in":[{"name":"alias@alice","uuid":"alias-uuid"}]}
		}}}`
	if err := os.WriteFile(c.UserDBPath, []byte(record), 0600); err != nil {
		t.Fatal(err)
	}
	if w := request(c, "/internal/raw/alice", "Bearer "+c.APIToken); w.Code != 404 {
		t.Fatal("disabled user exposed without opt-in")
	}
	c.IncludeDisabledUsers = true
	w := request(c, "/internal/raw/alice", "Bearer "+c.APIToken)
	if w.Code != 200 {
		t.Fatalf("%d: %s", w.Code, w.Body.String())
	}
	var payload Payload
	if err := json.Unmarshal(w.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Inbounds) != 2 || payload.Enabled || payload.Usage.QuotaGB != 3.5 ||
		payload.Usage.ResetDay != 32 || payload.Usage.ExpireAt != "2030-01-01" {
		t.Fatalf("incorrect persisted projection: %+v", payload)
	}
	for _, required := range []string{"persisted-uuid", "alias-uuid", "original-login@alice", "persisted-password"} {
		if !strings.Contains(w.Body.String(), required) {
			t.Fatalf("missing credential %s", required)
		}
	}
	for _, forbidden := range []string{"SECRET", "alice-uuid", "bob-secret", "private-secret"} {
		if strings.Contains(w.Body.String(), forbidden) {
			t.Fatalf("projection leaked %s", forbidden)
		}
	}
	for _, invalid := range []string{
		strings.Replace(record, `"original@alice"`, `"original@bob"`, 1),
		strings.Replace(record, `"nodes":["reality-in","socks-in"],`, "", 1),
	} {
		if err := os.WriteFile(c.UserDBPath, []byte(invalid), 0600); err != nil {
			t.Fatal(err)
		}
		if w := request(c, "/internal/raw/alice", "Bearer "+c.APIToken); w.Code != 503 {
			t.Fatalf("invalid persisted identity/permissions accepted: %d", w.Code)
		}
	}
	record = strings.Replace(record, `"enabled":false`, `"enabled":true`, 1)
	if err := os.WriteFile(c.UserDBPath, []byte(record), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(c.ConfigPath, []byte(`{"inbounds":[{"tag":"reality-in","type":"vless","users":[]}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if w := request(c, "/internal/raw/alice", "Bearer "+c.APIToken); w.Code != 404 {
		t.Fatal("persisted credentials bypassed enabled-user runtime eligibility")
	}
}
