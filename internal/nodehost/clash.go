package nodehost

import (
	"errors"
	"fmt"
	"net"
	"strings"
)

// clash emits JSON-compatible YAML for current Mihomo clients. It deliberately
// builds client fields rather than copying server TLS configuration.
func (h *host) clash(p RawPayload) (Object, error) {
	serverTLS := map[string]Object{}
	for _, raw := range list(h.config["inbounds"]) {
		in := object(raw)
		serverTLS[text(in["tag"])] = project(object(in["tls"]), "enabled", "alpn")
	}
	proxies, names := []any{}, []any{}
	used := map[string]bool{"DIRECT": true, "REJECT": true, "REJECT-DROP": true, "PASS": true, "COMPATIBLE": true, "GLOBAL": true}
	for _, in := range p.Inbounds {
		for _, raw := range list(in["users"]) {
			proxy, err := clashProxy(p, in, object(raw), serverTLS[text(in["tag"])])
			if err != nil {
				return nil, err
			}
			tag := text(in["tag"])
			name := tag
			for suffix := 2; used[name]; suffix++ {
				name = fmt.Sprintf("%s [%d]", tag, suffix)
			}
			used[name] = true
			proxy["name"] = name
			proxies = append(proxies, proxy)
			names = append(names, name)
		}
	}
	if len(proxies) == 0 {
		return nil, errors.New("user has no exportable credentials")
	}
	group := "SUBFLOW"
	for used[group] {
		group += "_"
	}
	return Object{
		"proxies":      proxies,
		"proxy-groups": []any{Object{"name": group, "type": "select", "proxies": names}},
		"rules":        []any{"MATCH," + group},
	}, nil
}

func clashProxy(p RawPayload, in, credential, serverTLS Object) (Object, error) {
	typ, tag := text(in["type"]), text(in["tag"])
	server := strings.Trim(p.PublicIP, "[]")
	transport := object(in["transport"])
	network := text(transport["type"])
	if network != "" && network != "ws" {
		return nil, fmt.Errorf("unsupported Clash transport %q for %q", network, tag)
	}
	if network == "ws" {
		if typ != "vless" && typ != "vmess" && typ != "trojan" {
			return nil, fmt.Errorf("unsupported Clash WebSocket protocol %q", typ)
		}
		if domain := text(p.WSDomains[typ]); domain != "" {
			server = strings.Trim(domain, "[]")
		}
	}
	port := number(in["listen_port"])
	if server == "" || port < 1 || port > 65535 {
		return nil, errors.New("Clash export requires a public address and valid port")
	}
	proxy := Object{"type": typ, "server": server, "port": port, "udp": true}
	required := []string{}
	switch typ {
	case "vless", "vmess":
		proxy["uuid"] = text(credential["uuid"])
		required = []string{"uuid"}
		if typ == "vmess" {
			proxy["alterId"] = 0
			proxy["cipher"] = "auto"
		} else if flow := text(credential["flow"]); flow != "" {
			proxy["flow"] = flow
		}
	case "trojan", "anytls":
		proxy["password"] = text(credential["password"])
		required = []string{"password"}
	case "tuic":
		proxy["uuid"] = text(credential["uuid"])
		proxy["password"] = text(credential["password"])
		proxy["congestion-controller"] = "bbr"
		proxy["udp-relay-mode"] = "native"
		required = []string{"uuid", "password"}
	case "shadowsocks":
		proxy["type"] = "ss"
		proxy["cipher"] = text(in["method"])
		if !strings.HasPrefix(text(in["method"]), "2022-") {
			return nil, errors.New("Clash export supports multi-user Shadowsocks 2022 only")
		}
		if text(in["password"]) == "" || text(credential["password"]) == "" {
			return nil, errors.New("Clash Shadowsocks 2022 export requires both PSKs")
		}
		proxy["password"] = text(in["password"]) + ":" + text(credential["password"])
		required = []string{"cipher"}
	case "socks":
		proxy["type"] = "socks5"
		proxy["username"] = text(credential["username"])
		proxy["password"] = text(credential["password"])
		required = []string{"username", "password"}
	default:
		return nil, fmt.Errorf("unsupported Clash protocol %q", typ)
	}
	for _, field := range required {
		if text(proxy[field]) == "" {
			return nil, fmt.Errorf("Clash export for %q requires %s", tag, field)
		}
	}
	tls := object(in["tls"])
	tlsEnabled := len(tls) > 0
	if enabled, ok := serverTLS["enabled"].(bool); ok {
		tlsEnabled = enabled
	}
	if typ == "trojan" || typ == "anytls" || typ == "tuic" {
		if !tlsEnabled {
			return nil, fmt.Errorf("Clash protocol %q requires TLS", typ)
		}
	} else if typ != "shadowsocks" {
		proxy["tls"] = tlsEnabled
	}
	if tlsEnabled {
		proxy["skip-cert-verify"] = false
		if sni := text(tls["server_name"]); sni != "" {
			key := "sni"
			if typ == "vless" || typ == "vmess" {
				key = "servername"
			}
			proxy[key] = sni
		}
		if alpn := list(serverTLS["alpn"]); len(alpn) > 0 {
			proxy["alpn"] = clone(alpn)
		}
		if reality := object(tls["reality"]); reality["enabled"] == true {
			if typ != "vless" {
				return nil, errors.New("Clash Reality export requires VLESS")
			}
			publicKey := text(p.Meta[tag]["public_key"])
			if publicKey == "" {
				return nil, errors.New("Clash Reality export requires the public key")
			}
			shortID := ""
			if ids := list(reality["short_id"]); len(ids) > 0 {
				shortID = text(ids[0])
			}
			proxy["client-fingerprint"] = "chrome"
			proxy["reality-opts"] = Object{"public-key": publicKey, "short-id": shortID}
		}
	}
	if network == "ws" {
		proxy["network"] = "ws"
		host := server
		if net.ParseIP(server) != nil && strings.Contains(server, ":") {
			host = "[" + server + "]"
		}
		proxy["ws-opts"] = Object{"path": text(transport["path"]), "headers": Object{"Host": host}}
	}
	return proxy, nil
}
