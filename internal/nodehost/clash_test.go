package nodehost

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"reflect"
	"strings"
	"testing"
)

func TestClashProtocolsAndSecrets(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	ordinary(h, "bob")
	h.opts.Config.VlessWSDomain = "vless.example.com"
	h.opts.Config.VmessWSDomain = "vmess.example.com"
	for i, protocol := range Protocols {
		addNode(t, h, protocol, protocol, 20000+i)
	}
	for _, raw := range list(h.config["inbounds"]) {
		in := object(raw)
		if text(in["tag"]) == "vless-ws" {
			in["tls"] = Object{"enabled": true, "server_name": "tls.example.com", "alpn": []any{"http/1.1"}, "key": "PRIVATE_SENTINEL", "certificate_provider": Object{"api_token": "TOKEN_SENTINEL"}}
		}
	}
	before, err := json.Marshal(h.config)
	if err != nil {
		t.Fatal(err)
	}
	p, err := h.payload("alice")
	if err != nil {
		t.Fatal(err)
	}
	result, err := h.clash(p)
	if err != nil {
		t.Fatal(err)
	}
	proxies := list(result["proxies"])
	if len(proxies) != len(Protocols) {
		t.Fatalf("got %d proxies", len(proxies))
	}
	for i, raw := range proxies {
		proxy := object(raw)
		tag := Protocols[i]
		credential := h.db.Users["alice"].Credentials[tag]
		if proxy["name"] != tag || number(proxy["port"]) != int64(20000+i) {
			t.Fatalf("%s identity/port: %v", tag, proxy)
		}
		switch tag {
		case "vless-reality":
			reality := object(proxy["reality-opts"])
			inReality := object(object(object(list(h.config["inbounds"])[i])["tls"])["reality"])
			if proxy["type"] != "vless" || proxy["uuid"] != credential["uuid"] || proxy["flow"] != "xtls-rprx-vision" || proxy["tls"] != true || proxy["servername"] != "example.com" || proxy["client-fingerprint"] != "chrome" || reality["public-key"] != h.meta[tag].PublicKey || reality["short-id"] != list(inReality["short_id"])[0] {
				t.Fatalf("Reality mapping: %v", proxy)
			}
		case "vless-ws", "vmess-ws":
			typ := strings.TrimSuffix(tag, "-ws")
			expectedServer := typ + ".example.com"
			ws := object(proxy["ws-opts"])
			if proxy["type"] != typ || proxy["uuid"] != credential["uuid"] || proxy["server"] != expectedServer || proxy["network"] != "ws" || ws["path"] != "/ws" || object(ws["headers"])["Host"] != expectedServer {
				t.Fatalf("WS mapping: %v", proxy)
			}
			if typ == "vless" {
				if proxy["tls"] != true || proxy["servername"] != "tls.example.com" || !reflect.DeepEqual(proxy["alpn"], []any{"http/1.1"}) {
					t.Fatalf("WS TLS mapping: %v", proxy)
				}
			} else if proxy["tls"] != false || proxy["cipher"] != "auto" || number(proxy["alterId"]) != 0 {
				t.Fatalf("VMess mapping: %v", proxy)
			}
		case "anytls", "trojan":
			if proxy["type"] != tag || proxy["password"] != credential["password"] || proxy["sni"] != "example.com" || proxy["skip-cert-verify"] != false {
				t.Fatalf("password TLS mapping: %v", proxy)
			}
		case "tuic":
			if proxy["type"] != "tuic" || proxy["uuid"] != credential["uuid"] || proxy["password"] != credential["password"] || proxy["sni"] != "example.com" || proxy["congestion-controller"] != "bbr" || proxy["udp-relay-mode"] != "native" || !reflect.DeepEqual(proxy["alpn"], []any{"h3"}) {
				t.Fatalf("TUIC mapping: %v", proxy)
			}
		case "shadowsocks":
			in := object(list(h.config["inbounds"])[i])
			if proxy["type"] != "ss" || proxy["cipher"] != "2022-blake3-aes-256-gcm" || proxy["password"] != text(in["password"])+":"+text(credential["password"]) {
				t.Fatalf("SS2022 mapping: %v", proxy)
			}
		case "socks":
			if proxy["type"] != "socks5" || proxy["username"] != credential["username"] || proxy["password"] != credential["password"] || proxy["server"] != h.opts.Config.PublicIP {
				t.Fatalf("SOCKS mapping: %v", proxy)
			}
		}
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"PRIVATE_SENTINEL", "TOKEN_SENTINEL", "private_key", "certificate", "api_token", "@bob", "@admin"} {
		if bytes.Contains(encoded, []byte(forbidden)) {
			t.Fatalf("Clash export leaked %q", forbidden)
		}
	}
	for _, username := range []string{"admin", "bob"} {
		for _, credential := range h.db.Users[username].Credentials {
			for _, field := range []string{"uuid", "password"} {
				if value := text(credential[field]); value != "" && bytes.Contains(encoded, []byte(value)) {
					t.Fatalf("Clash export leaked %s's %s", username, field)
				}
			}
		}
	}
	after, err := json.Marshal(h.config)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("export changed server configuration")
	}
}

func TestClashAliasesPermissionsAndCLI(t *testing.T) {
	h := testHost(t)
	ordinary(h, "alice")
	addNode(t, h, "socks", "SUBFLOW", 1080)
	addNode(t, h, "socks", "forbidden", 1081)
	h.db.Users["alice"].Nodes = []string{"SUBFLOW"}
	h.db.Users["alice"].CredentialAliases = map[string][]Object{"SUBFLOW": {{"username": "alternate@alice", "password": "alias-password"}}}
	saveHost(t, h)
	var out bytes.Buffer
	err := RunWithOptions(context.Background(), []string{"export", "--name", "alice", "--format", "clash"}, strings.NewReader(""), &out, io.Discard, h.opts)
	if err != nil {
		t.Fatal(err)
	}
	var config Object
	if err := json.Unmarshal(out.Bytes(), &config); err != nil {
		t.Fatalf("not JSON-compatible YAML: %v", err)
	}
	proxies := list(config["proxies"])
	if len(proxies) != 2 || object(proxies[0])["name"] != "SUBFLOW" || object(proxies[1])["name"] != "SUBFLOW [2]" || object(proxies[1])["username"] != "alternate@alice" || object(proxies[1])["password"] != "alias-password" {
		t.Fatalf("aliases: %v", proxies)
	}
	group := object(list(config["proxy-groups"])[0])
	if group["name"] != "SUBFLOW_" || group["type"] != "select" || !reflect.DeepEqual(list(group["proxies"]), []any{"SUBFLOW", "SUBFLOW [2]"}) || list(config["rules"])[0] != "MATCH,SUBFLOW_" {
		t.Fatalf("group references: %v", config)
	}
	out.Reset()
	if err := RunWithOptions(context.Background(), []string{"export", "--name", "alice", "--format", "unknown"}, strings.NewReader(""), &out, io.Discard, h.opts); err == nil || !strings.Contains(err.Error(), "unknown export format") || out.Len() != 0 {
		t.Fatalf("unsupported format: %v, %s", err, out.String())
	}
}

func TestClashRejectsIncompleteAndUnsupported(t *testing.T) {
	h := testHost(t)
	addNode(t, h, "vless-reality", "reality", 443)
	p, err := h.payload("admin")
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		edit func(*RawPayload)
	}{
		{"type", func(p *RawPayload) { p.Inbounds[0]["type"] = "unsupported" }},
		{"transport", func(p *RawPayload) { p.Inbounds[0]["transport"] = Object{"type": "grpc"} }},
		{"uuid", func(p *RawPayload) { delete(object(list(p.Inbounds[0]["users"])[0]), "uuid") }},
		{"address", func(p *RawPayload) { p.PublicIP = "" }},
		{"port", func(p *RawPayload) { p.Inbounds[0]["listen_port"] = 0 }},
		{"public-key", func(p *RawPayload) { p.Meta = map[string]Object{} }},
		{"empty", func(p *RawPayload) { p.Inbounds = nil }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			copy := clone(p)
			tt.edit(&copy)
			if _, err := h.clash(copy); err == nil {
				t.Fatal("invalid export accepted")
			}
		})
	}
}

func TestClashDisabledTLSAndIPv6(t *testing.T) {
	h := testHost(t)
	h.opts.Config.PublicIP = "[2001:db8::1]"
	addNode(t, h, "vmess-ws", "ws", 8080)
	in := object(list(h.config["inbounds"])[0])
	in["tls"] = Object{"enabled": false, "server_name": "disabled.example.com"}
	p, err := h.payload("admin")
	if err != nil {
		t.Fatal(err)
	}
	result, err := h.clash(p)
	if err != nil {
		t.Fatal(err)
	}
	proxy := object(list(result["proxies"])[0])
	if proxy["tls"] != false || proxy["server"] != "2001:db8::1" || proxy["servername"] != nil || object(object(proxy["ws-opts"])["headers"])["Host"] != "[2001:db8::1]" {
		t.Fatalf("disabled TLS/IPv6: %v", proxy)
	}
}

func TestClashReservedNamesAndUnknownFormatBeforeInitialization(t *testing.T) {
	h := testHost(t)
	var out bytes.Buffer
	err := RunWithOptions(context.Background(), []string{"export", "--format", "unsupported"}, strings.NewReader(""), &out, io.Discard, h.opts)
	if err == nil || !strings.Contains(err.Error(), "unknown export format") || out.Len() != 0 {
		t.Fatalf("uninitialized unknown format: %v", err)
	}
	addNode(t, h, "socks", "DIRECT", 1080)
	p, err := h.payload("admin")
	if err != nil {
		t.Fatal(err)
	}
	config, err := h.clash(p)
	if err != nil {
		t.Fatal(err)
	}
	if object(list(config["proxies"])[0])["name"] != "DIRECT [2]" {
		t.Fatal("export shadowed a built-in proxy")
	}
}
