package nodehost

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"strings"
	"time"
)

var Protocols = []string{"vless-reality", "vless-ws", "vmess-ws", "anytls", "trojan", "tuic", "shadowsocks", "socks"}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	return hex.EncodeToString(b), nil
}
func randomBase64(n int) (string, error) {
	b := make([]byte, n)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	return base64.StdEncoding.EncodeToString(b), nil
}
func uuid() (string, error) {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	b[6] = b[6]&15 | 64
	b[8] = b[8]&63 | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

func certificate(server string, now time.Time) (Object, error) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	t := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: server}, NotBefore: now.Add(-time.Hour), NotAfter: now.AddDate(1, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true}
	if ip := net.ParseIP(server); ip != nil {
		t.IPAddresses = []net.IP{ip}
	} else {
		t.DNSNames = []string{server}
	}
	der, err := x509.CreateCertificate(rand.Reader, t, t, &k.PublicKey, k)
	if err != nil {
		return nil, err
	}
	key, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		return nil, err
	}
	return Object{"enabled": true, "server_name": server, "certificate": []any{string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))}, "key": []any{string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}))}}, nil
}

func (h *host) addProtocol(protocol, tag string, port int, server, path string) error {
	if !validName(tag) || port < 1 || port > 65535 {
		return errors.New("tag/port invalid")
	}
	if !contains(Protocols, protocol) {
		return errors.New("unknown protocol")
	}
	for _, v := range list(h.config["inbounds"]) {
		in := object(v)
		if text(in["tag"]) == tag {
			return errors.New("tag already exists")
		}
		if number(in["listen_port"]) == int64(port) {
			return errors.New("port already exists")
		}
	}
	if server == "" {
		server = "www.microsoft.com"
	}
	in := Object{"tag": tag, "listen": "::", "listen_port": port}
	meta := nodeMeta{Protocol: protocol}
	switch protocol {
	case "vless-reality":
		in["type"] = "vless"
		k, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			return err
		}
		short, err := randomHex(8)
		if err != nil {
			return err
		}
		meta.PublicKey = base64.RawURLEncoding.EncodeToString(k.PublicKey().Bytes())
		in["tls"] = Object{"enabled": true, "server_name": server, "reality": Object{"enabled": true, "handshake": Object{"server": server, "server_port": 443}, "private_key": base64.RawURLEncoding.EncodeToString(k.Bytes()), "short_id": []any{short}}}
	case "vless-ws", "vmess-ws":
		in["type"] = strings.TrimSuffix(protocol, "-ws")
		if path == "" {
			path = "/" + tag
		}
		if !strings.HasPrefix(path, "/") {
			return errors.New("WebSocket path must start with /")
		}
		in["transport"] = Object{"type": "ws", "path": path}
	case "anytls", "trojan", "tuic":
		in["type"] = protocol
		meta.TLSMode = "self-signed"
		tls, err := certificate(server, h.opts.Now())
		if err != nil {
			return err
		}
		in["tls"] = tls
		if protocol == "tuic" {
			in["congestion_control"] = "bbr"
			tls["alpn"] = []any{"h3"}
		}
	case "shadowsocks":
		in["type"] = "shadowsocks"
		in["method"] = "2022-blake3-aes-256-gcm"
		password, err := randomBase64(32)
		if err != nil {
			return err
		}
		in["password"] = password
	case "socks":
		in["type"] = "socks"
	}
	h.config["inbounds"] = append(list(h.config["inbounds"]), in)
	h.meta[tag] = meta
	return h.ensureCredentials()
}

func (h *host) ensureCredentials() error {
	if len(list(h.config["inbounds"])) > 128 {
		return errors.New("at most 128 inbounds are supported")
	}
	for _, v := range list(h.config["inbounds"]) {
		in := object(v)
		tag := text(in["tag"])
		typ := text(in["type"])
		if !validName(tag) {
			return errors.New("invalid inbound tag")
		}
		for _, name := range sortedUsers(h.db) {
			u := h.db.Users[name]
			if u.Credentials == nil {
				u.Credentials = map[string]Object{}
			}
			if u.Credentials[tag] != nil {
				continue
			}
			id := tag + "@" + name
			credential := Object{"name": id}
			switch typ {
			case "vless", "vmess":
				v, e := uuid()
				if e != nil {
					return e
				}
				credential["uuid"] = v
				if h.meta[tag].Protocol == "vless-reality" {
					credential["flow"] = "xtls-rprx-vision"
				}
			case "tuic":
				v, e := uuid()
				if e != nil {
					return e
				}
				credential["uuid"] = v
				p, e := randomHex(24)
				if e != nil {
					return e
				}
				credential["password"] = p
			case "shadowsocks":
				p, e := randomBase64(32)
				if e != nil {
					return e
				}
				credential["password"] = p
			case "socks":
				delete(credential, "name")
				credential["username"] = id
				p, e := randomHex(24)
				if e != nil {
					return e
				}
				credential["password"] = p
			case "anytls", "trojan":
				p, e := randomHex(24)
				if e != nil {
					return e
				}
				credential["password"] = p
			default:
				return fmt.Errorf("unsupported inbound type %q", typ)
			}
			u.Credentials[tag] = credential
		}
	}
	return nil
}

func (h *host) render() error {
	if err := h.ensureCredentials(); err != nil {
		return err
	}
	var stats []any
	statNames := map[string]bool{}
	rules := []any{}
	routeSets := []any{}
	for _, r := range h.routing.Rules {
		routeSets = append(routeSets, Object{"type": "local", "tag": r.Tag, "format": "source", "path": r.Path})
	}
	for _, v := range list(h.config["inbounds"]) {
		in := object(v)
		tag := text(in["tag"])
		users := []any{}
		allowed := []any{}
		for _, name := range sortedUsers(h.db) {
			u := h.db.Users[name]
			for _, credential := range credentialsFor(u, tag) {
				identity := credentialIdentity(credential)
				if name != "admin" && !statNames[identity] {
					stats = append(stats, identity)
					statNames[identity] = true
				}
				if h.active(name, tag) {
					users = append(users, credential)
					allowed = append(allowed, identity)
				}
			}
		}
		// An empty SOCKS user list means unauthenticated access; a random
		// unexported sentinel prevents it even before the reject route is hit.
		if len(users) == 0 {
			existing := list(in["users"])
			if len(existing) == 1 && (strings.HasPrefix(text(object(existing[0])["username"]), "disabled-") || strings.HasPrefix(text(object(existing[0])["name"]), "disabled-")) {
				users = existing
			} else {
				sentinel, e := randomHex(32)
				if e != nil {
					return e
				}
				switch text(in["type"]) {
				case "socks":
					users = append(users, Object{"username": "disabled-" + sentinel, "password": sentinel})
				case "shadowsocks":
					p, e := randomBase64(32)
					if e != nil {
						return e
					}
					users = append(users, Object{"name": "disabled-" + sentinel, "password": p})
				}
			}
		}
		in["users"] = users
		if len(allowed) == 0 {
			continue
		}
		for _, r := range h.routing.Rules {
			rules = append(rules, Object{"inbound": []any{tag}, "auth_user": allowed, "rule_set": []any{r.Tag}, "action": "route", "outbound": r.Outbound})
		}
		outbound := h.routing.Full
		if outbound == "" {
			outbound = "direct"
		}
		rules = append(rules, Object{"inbound": []any{tag}, "auth_user": allowed, "action": "route", "outbound": outbound})
	}
	rules = append(rules, Object{"action": "reject"})
	h.config["route"] = Object{"rules": rules, "rule_set": routeSets}
	outbounds := []any{Object{"type": "direct", "tag": "direct"}}
	if h.routing.Relay != nil {
		outbounds = append(outbounds, h.routing.Relay)
	}
	if h.routing.WARP != nil {
		outbounds = append(outbounds, h.routing.WARP)
	}
	h.config["outbounds"] = outbounds
	h.config["experimental"] = Object{"v2ray_api": Object{"listen": "127.0.0.1:10085", "stats": Object{"enabled": true, "users": stats}}}
	return nil
}
