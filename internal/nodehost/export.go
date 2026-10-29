package nodehost

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
)

type RawPayload struct {
	SchemaVersion int               `json:"schema_version"`
	Username      string            `json:"username"`
	Enabled       bool              `json:"enabled"`
	Usage         Object            `json:"usage"`
	Inbounds      []Object          `json:"inbounds"`
	Meta          map[string]Object `json:"meta"`
	PublicIP      string            `json:"public_ip"`
	WSDomains     Object            `json:"ws_domains"`
}

func project(src Object, keys ...string) Object {
	dst := Object{}
	for _, k := range keys {
		if v, ok := src[k]; ok {
			dst[k] = clone(v)
		}
	}
	return dst
}

func (h *host) payload(name string) (RawPayload, error) {
	u := h.db.Users[name]
	if u == nil {
		return RawPayload{}, errors.New("user not found")
	}
	c := h.opts.Config
	p := RawPayload{SchemaVersion: 1, Username: name, Enabled: u.Enabled, PublicIP: c.PublicIP, WSDomains: Object{"vless": c.VlessWSDomain, "vmess": c.VmessWSDomain}, Meta: map[string]Object{}, Inbounds: []Object{}}
	quota, up, down := u.QuotaGB, u.Up, u.Down
	if name == "admin" {
		quota = 0
		up = 0
		down = 0
	}
	p.Usage = Object{"username": name, "enabled": u.Enabled, "disabled_reason": u.DisabledReason, "quota_gb": quota, "used_up_bytes": up, "used_down_bytes": down, "manual_added_bytes": u.Manual, "last_reset_period": u.LastReset, "reset_day": u.ResetDay, "expire_at": u.ExpireAt}
	for _, v := range list(h.config["inbounds"]) {
		in := object(v)
		tag := text(in["tag"])
		credential := u.Credentials[tag]
		if credential == nil || !contains(u.Nodes, tag) {
			continue
		}
		safe := project(in, "type", "tag", "listen_port")
		if text(in["type"]) == "shadowsocks" {
			for k, v := range project(in, "method", "password") {
				safe[k] = v
			}
		}
		safeUsers := []any{}
		for _, credential := range credentialsFor(u, tag) {
			safeUsers = append(safeUsers, project(credential, "name", "username", "uuid", "password", "flow"))
		}
		safe["users"] = safeUsers
		if tls := object(in["tls"]); len(tls) > 0 {
			safeTLS := project(tls, "server_name")
			if reality := object(tls["reality"]); len(reality) > 0 {
				safeTLS["reality"] = project(reality, "enabled", "short_id")
			}
			safe["tls"] = safeTLS
		}
		if transport := object(in["transport"]); len(transport) > 0 {
			safe["transport"] = project(transport, "type", "path")
		}
		if key := h.meta[tag].PublicKey; key != "" {
			p.Meta[tag] = Object{"public_key": key}
		}
		p.Inbounds = append(p.Inbounds, safe)
	}
	if len(p.Inbounds) == 0 {
		return p, errors.New("user has no permitted nodes")
	}
	return p, nil
}

func URI(p RawPayload, in Object) (string, error) {
	typ, tag := text(in["type"]), text(in["tag"])
	users := list(in["users"])
	if len(users) != 1 {
		return "", errors.New("export requires exactly one user")
	}
	u := object(users[0])
	server := p.PublicIP
	transport := object(in["transport"])
	tls := object(in["tls"])
	if text(transport["type"]) == "ws" {
		if domain := text(p.WSDomains[typ]); domain != "" {
			server = domain
		}
	}
	if server == "" {
		return "", errors.New("public address is not configured")
	}
	port := number(in["listen_port"])
	if typ == "vmess" {
		tlsMode := ""
		if len(tls) > 0 {
			tlsMode = "tls"
		}
		node := Object{"v": "2", "ps": tag, "add": server, "port": strconv.FormatInt(port, 10), "id": text(u["uuid"]), "aid": "0", "scy": "auto", "net": "ws", "type": "none", "host": server, "path": text(transport["path"]), "tls": tlsMode, "sni": text(tls["server_name"])}
		b, _ := json.Marshal(node)
		return "vmess://" + base64.StdEncoding.EncodeToString(b), nil
	}
	q := url.Values{}
	if len(tls) > 0 {
		q.Set("security", "tls")
		q.Set("sni", text(tls["server_name"]))
	}
	if r := object(tls["reality"]); r["enabled"] == true {
		q.Set("security", "reality")
		q.Set("pbk", text(p.Meta[tag]["public_key"]))
		q.Set("fp", "chrome")
		if ids := list(r["short_id"]); len(ids) > 0 {
			q.Set("sid", text(ids[0]))
		}
	}
	if text(transport["type"]) == "ws" {
		q.Set("type", "ws")
		q.Set("path", text(transport["path"]))
		q.Set("host", server)
	}
	var userInfo *url.Userinfo
	scheme := typ
	switch typ {
	case "vless":
		userInfo = url.User(text(u["uuid"]))
		if flow := text(u["flow"]); flow != "" {
			q.Set("flow", flow)
		}
		q.Set("encryption", "none")
	case "trojan", "anytls":
		userInfo = url.User(text(u["password"]))
	case "tuic":
		userInfo = url.UserPassword(text(u["uuid"]), text(u["password"]))
		q.Set("congestion_control", "bbr")
		q.Set("alpn", "h3")
	case "socks":
		scheme = "socks5"
		userInfo = url.UserPassword(text(u["username"]), text(u["password"]))
	case "shadowsocks":
		scheme = "ss"
		userInfo = url.User(base64.RawURLEncoding.EncodeToString([]byte(text(in["method"]) + ":" + text(in["password"]) + ":" + text(u["password"]))))
	default:
		return "", fmt.Errorf("unsupported export type %q", typ)
	}
	result := url.URL{Scheme: scheme, Host: net.JoinHostPort(strings.Trim(server, "[]"), strconv.FormatInt(port, 10)), User: userInfo, RawQuery: q.Encode(), Fragment: tag}
	return result.String(), nil
}
