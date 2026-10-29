package nodehost

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"net"
	"net/mail"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

func validDomain(domain string) bool {
	if len(domain) > 253 || net.ParseIP(domain) != nil || !strings.Contains(domain, ".") {
		return false
	}
	for _, label := range strings.Split(domain, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, r := range label {
			if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-') {
				return false
			}
		}
	}
	return true
}

func (h *host) tlsInbound(tag string) (Object, error) {
	for _, v := range list(h.config["inbounds"]) {
		in := object(v)
		if text(in["tag"]) != tag {
			continue
		}
		switch text(in["type"]) {
		case "vless", "vmess", "trojan", "anytls", "tuic":
		default:
			return nil, errors.New("protocol does not support TLS")
		}
		if len(object(object(in["tls"])["reality"])) > 0 {
			return nil, errors.New("Reality does not use certificate/ACME TLS")
		}
		return in, nil
	}
	return nil, errors.New("protocol not found")
}

func cleanTLS(in Object, server string) Object {
	config := object(in["tls"])
	for _, key := range []string{"certificate", "certificate_path", "key", "key_path", "acme", "certificate_provider"} {
		delete(config, key)
	}
	config["enabled"] = true
	config["server_name"] = server
	in["tls"] = config
	return config
}

func (h *host) configureACME(ctx context.Context, tag, domain, email, tokenPath, mode, ca string) error {
	if !validDomain(domain) {
		return errors.New("ACME DNS-01 requires a DNS hostname")
	}
	if address, err := mail.ParseAddress(email); err != nil || address.Address != email {
		return errors.New("invalid ACME email")
	}
	if ca != "letsencrypt" && ca != "zerossl" {
		return errors.New("ACME CA must be letsencrypt or zerossl")
	}
	in, err := h.tlsInbound(tag)
	if err != nil {
		return err
	}
	token, err := os.ReadFile(tokenPath)
	if err != nil {
		return errors.New("cannot read Cloudflare token file")
	}
	secret := strings.TrimSpace(string(token))
	if len(secret) == 0 || len(secret) > 4096 || strings.ContainsAny(secret, " \t\r\n\x00") {
		return errors.New("invalid Cloudflare token file")
	}
	if mode == "auto" {
		version, err := h.execute(ctx, "sing-box", "version")
		if err != nil {
			return errors.New("cannot detect sing-box version; specify --acme-mode inline|provider or import a certificate")
		}
		parts := regexp.MustCompile(`sing-box version (\d+)\.(\d+)`).FindStringSubmatch(string(version))
		if len(parts) != 3 {
			return errors.New("unrecognized sing-box version; specify --acme-mode or import a certificate")
		}
		major, _ := strconv.Atoi(parts[1])
		minor, _ := strconv.Atoi(parts[2])
		if major > 1 || major == 1 && minor >= 14 {
			mode = "provider"
		} else {
			mode = "inline"
		}
	}
	if mode != "inline" && mode != "provider" {
		return errors.New("ACME mode must be auto, inline or provider")
	}
	directory := filepath.Join(h.opts.Config.MetaPath+".acme", tag)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	if err := os.Chmod(directory, 0700); err != nil {
		return err
	}
	acme := Object{"domain": []any{domain}, "default_server_name": domain, "email": email, "provider": ca, "data_directory": directory,
		"disable_http_challenge": true, "disable_tls_alpn_challenge": true,
		"dns01_challenge": Object{"provider": "cloudflare", "api_token": secret}}
	config := cleanTLS(in, domain)
	if mode == "provider" {
		acme["type"] = "acme"
		config["certificate_provider"] = acme
	} else {
		config["acme"] = acme
	}
	meta := h.meta[tag]
	meta.TLSMode = "acme-" + mode
	h.meta[tag] = meta
	return nil
}

func (h *host) importCertificate(tag, server, certPath, keyPath string) error {
	in, err := h.tlsInbound(tag)
	if err != nil {
		return err
	}
	if server == "" {
		server = text(object(in["tls"])["server_name"])
	}
	if server == "" {
		return errors.New("certificate import requires --server-name")
	}
	certificate, err := os.ReadFile(certPath)
	if err != nil {
		return errors.New("cannot read certificate file")
	}
	key, err := os.ReadFile(keyPath)
	if err != nil {
		return errors.New("cannot read private-key file")
	}
	if len(certificate) > 1<<20 || len(key) > 1<<20 {
		return errors.New("certificate/key file too large")
	}
	pair, err := tls.X509KeyPair(certificate, key)
	if err != nil {
		return errors.New("certificate and private key are invalid or do not match")
	}
	if len(pair.Certificate) == 0 {
		return errors.New("empty certificate chain")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return errors.New("invalid leaf certificate")
	}
	now := h.opts.Now()
	if now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
		return errors.New("certificate is not currently valid")
	}
	if err := leaf.VerifyHostname(server); err != nil {
		return errors.New("certificate does not cover server name")
	}
	config := cleanTLS(in, server)
	config["certificate"] = []any{string(certificate)}
	config["key"] = []any{string(key)}
	meta := h.meta[tag]
	meta.TLSMode = "imported"
	h.meta[tag] = meta
	return nil
}

func (h *host) canRegenerateCertificate(in Object) bool {
	mode := h.meta[text(in["tag"])].TLSMode
	if mode != "" {
		return mode == "self-signed"
	}
	config := object(in["tls"])
	if config["acme"] != nil || config["certificate_provider"] != nil || config["certificate_path"] != nil || config["key_path"] != nil {
		return false
	}
	chain := list(config["certificate"])
	if len(chain) == 0 {
		return false
	}
	block, _ := pem.Decode([]byte(text(chain[0])))
	if block == nil {
		return false
	}
	leaf, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return false
	}
	return bytes.Equal(leaf.RawIssuer, leaf.RawSubject) && leaf.CheckSignature(leaf.SignatureAlgorithm, leaf.RawTBSCertificate, leaf.Signature) == nil
}
