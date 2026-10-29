package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"

	"github.com/arnozeng98/subflow/internal/settings"
	"github.com/arnozeng98/subflow/internal/state"
)

var ErrNotFound = errors.New("user has no available subscription")

type Usage struct {
	Username         string  `json:"username"`
	Enabled          bool    `json:"enabled"`
	DisabledReason   *string `json:"disabled_reason"`
	QuotaGB          float64 `json:"quota_gb"`
	UsedUpBytes      int64   `json:"used_up_bytes"`
	UsedDownBytes    int64   `json:"used_down_bytes"`
	ManualAddedBytes int64   `json:"manual_added_bytes"`
	LastResetPeriod  string  `json:"last_reset_period"`
	ResetDay         int     `json:"reset_day"`
	ExpireAt         string  `json:"expire_at"`
}

type Payload struct {
	SchemaVersion int                          `json:"schema_version"`
	Username      string                       `json:"username"`
	Enabled       bool                         `json:"enabled"`
	Usage         Usage                        `json:"usage"`
	Inbounds      []map[string]json.RawMessage `json:"inbounds"`
	Meta          map[string]RealityMeta       `json:"meta"`
	PublicIP      string                       `json:"public_ip"`
	WSDomains     WSDomains                    `json:"ws_domains"`
}

type RealityMeta struct {
	PublicKey string `json:"public_key"`
}

type WSDomains struct {
	Vless string `json:"vless"`
	Vmess string `json:"vmess"`
}

func NormalizeUsername(value string) (string, bool) {
	value = strings.TrimSpace(value)
	if len(value) == 0 || len(value) > 64 {
		return "", false
	}
	for _, r := range value {
		if r != '-' && r != '_' && (r < 'a' || r > 'z') && (r < 'A' || r > 'Z') && (r < '0' || r > '9') {
			return "", false
		}
	}
	return value, true
}

func BusinessUsername(value string) string {
	if _, username, ok := strings.Cut(value, "@"); ok {
		return username
	}
	return "admin"
}

func BuildPayload(ctx context.Context, c settings.Config, username string) (Payload, error) {
	result := Payload{
		SchemaVersion: 1,
		Username:      username,
		Meta:          make(map[string]RealityMeta),
		Inbounds:      make([]map[string]json.RawMessage, 0),
		PublicIP:      c.PublicIP,
		WSDomains:     WSDomains{Vless: c.VlessWSDomain, Vmess: c.VmessWSDomain},
	}
	err := state.WithLock(ctx, c.LockPath, func() error {
		var db struct {
			Users map[string]json.RawMessage `json:"users"`
		}
		if err := state.ReadJSON(c.UserDBPath, &db); err != nil {
			return err
		}
		raw, exists := db.Users[username]
		if !exists || string(raw) == "null" || string(raw) == "{}" {
			return ErrNotFound
		}
		usage, err := decodeUsage(username, raw)
		if err != nil {
			return fmt.Errorf("invalid user record: %w", err)
		}
		if !usage.Enabled && !c.IncludeDisabledUsers {
			return ErrNotFound
		}
		var stored struct {
			Nodes             *[]string                               `json:"nodes"`
			Credentials       map[string]map[string]json.RawMessage   `json:"credentials"`
			CredentialAliases map[string][]map[string]json.RawMessage `json:"credential_aliases"`
		}
		if !usage.Enabled {
			if err := json.Unmarshal(raw, &stored); err != nil {
				return fmt.Errorf("invalid stored user credentials: %w", err)
			}
			if (len(stored.Credentials) > 0 || len(stored.CredentialAliases) > 0) && stored.Nodes == nil {
				return errors.New("stored credentials require explicit node permissions")
			}
		}
		result.Usage, result.Enabled = usage, usage.Enabled
		var config struct {
			Inbounds []map[string]json.RawMessage `json:"inbounds"`
		}
		if err := state.ReadJSON(c.ConfigPath, &config); err != nil {
			return err
		}
		var metadata map[string]json.RawMessage
		if err := state.ReadJSON(c.MetaPath, &metadata); err != nil {
			return err
		}
		for _, inbound := range config.Inbounds {
			tag, err := optionalString(inbound["tag"])
			if err != nil {
				return fmt.Errorf("invalid inbound tag: %w", err)
			}
			if tag == "" {
				continue
			}
			if stored.Nodes != nil && !slices.Contains(*stored.Nodes, "*") && !slices.Contains(*stored.Nodes, tag) {
				continue
			}
			var users []map[string]json.RawMessage
			if credential, ok := stored.Credentials[tag]; ok {
				users = append(users, credential)
			}
			users = append(users, stored.CredentialAliases[tag]...)
			persisted := len(users) > 0
			if rawUsers := inbound["users"]; !persisted && len(rawUsers) > 0 {
				if err := json.Unmarshal(rawUsers, &users); err != nil {
					return fmt.Errorf("invalid inbound users: %w", err)
				}
			}
			matching := make([]map[string]json.RawMessage, 0)
			for _, user := range users {
				name, err := optionalString(user["name"])
				if err != nil {
					return fmt.Errorf("invalid node user name: %w", err)
				}
				if name == "" {
					name, err = optionalString(user["username"])
					if err != nil {
						return fmt.Errorf("invalid node username: %w", err)
					}
				}
				if name != "" && BusinessUsername(name) == username {
					matching = append(matching, pickFields(user, "name", "username", "uuid", "password", "flow"))
				} else if persisted {
					return errors.New("stored credential identity does not match its user")
				}
			}
			if len(matching) == 0 {
				continue
			}
			userJSON, err := json.Marshal(matching)
			if err != nil {
				return err
			}
			projected, err := projectInbound(inbound)
			if err != nil {
				return fmt.Errorf("invalid inbound projection: %w", err)
			}
			projected["users"] = userJSON
			result.Inbounds = append(result.Inbounds, projected)
			if rawMeta, ok := metadata[tag]; ok && string(rawMeta) != "null" {
				var meta RealityMeta
				if err := json.Unmarshal(rawMeta, &meta); err != nil {
					return fmt.Errorf("invalid inbound metadata: %w", err)
				}
				if meta.PublicKey != "" {
					result.Meta[tag] = meta
				}
			}
		}
		if len(result.Inbounds) == 0 {
			return ErrNotFound
		}
		return nil
	})
	return result, err
}

func pickFields(source map[string]json.RawMessage, fields ...string) map[string]json.RawMessage {
	result := make(map[string]json.RawMessage)
	for _, field := range fields {
		if value, ok := source[field]; ok {
			result[field] = value
		}
	}
	return result
}

func projectInbound(source map[string]json.RawMessage) (map[string]json.RawMessage, error) {
	result := pickFields(source, "type", "tag", "listen_port")
	kind, err := optionalString(source["type"])
	if err != nil {
		return nil, err
	}
	if kind == "shadowsocks" {
		for key, value := range pickFields(source, "method", "password") {
			result[key] = value
		}
	}
	for field, allowed := range map[string][]string{
		"transport": {"type", "path"}, "tls": {"server_name"},
	} {
		if raw := source[field]; len(raw) > 0 && string(raw) != "null" {
			var object map[string]json.RawMessage
			if err := json.Unmarshal(raw, &object); err != nil {
				return nil, err
			}
			projected := pickFields(object, allowed...)
			if field == "tls" && len(object["reality"]) > 0 && string(object["reality"]) != "null" {
				var reality map[string]json.RawMessage
				if err := json.Unmarshal(object["reality"], &reality); err != nil {
					return nil, err
				}
				value, err := json.Marshal(pickFields(reality, "enabled", "short_id"))
				if err != nil {
					return nil, err
				}
				projected["reality"] = value
			}
			encoded, err := json.Marshal(projected)
			if err != nil {
				return nil, err
			}
			result[field] = encoded
		}
	}
	return result, nil
}

func decodeUsage(username string, raw json.RawMessage) (Usage, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return Usage{}, err
	}
	u := Usage{Username: username, ExpireAt: "0"}
	for name, target := range map[string]any{
		"enabled": &u.Enabled, "disabled_reason": &u.DisabledReason,
		"last_reset_period": &u.LastResetPeriod,
	} {
		if value, exists := fields[name]; exists {
			if err := json.Unmarshal(value, target); err != nil {
				return u, fmt.Errorf("%s: %w", name, err)
			}
		}
	}
	for name, target := range map[string]*int64{
		"used_up_bytes":   &u.UsedUpBytes,
		"used_down_bytes": &u.UsedDownBytes, "manual_added_bytes": &u.ManualAddedBytes,
	} {
		value, err := integer(fields[name])
		if err != nil {
			return u, fmt.Errorf("%s: %w", name, err)
		}
		*target = value
	}
	if value, err := optionalString(fields["quota_gb"]); err != nil {
		return u, err
	} else if value != "" {
		u.QuotaGB, err = strconv.ParseFloat(value, 64)
		if err != nil || math.IsNaN(u.QuotaGB) || math.IsInf(u.QuotaGB, 0) || u.QuotaGB < 0 {
			return u, errors.New("quota_gb must be finite and nonnegative")
		}
	}
	reset, err := integer(fields["reset_day"])
	if err != nil || reset < 0 || reset > 32 {
		return u, errors.New("reset_day must be between 0 and 32")
	}
	u.ResetDay = int(reset)
	if value := fields["expire_at"]; len(value) != 0 && string(value) != "null" {
		expire, err := optionalString(value)
		if err != nil {
			return u, fmt.Errorf("expire_at: %w", err)
		}
		if expire != "" {
			u.ExpireAt = expire
		}
	}
	return u, nil
}

func integer(raw json.RawMessage) (int64, error) {
	value, err := optionalString(raw)
	if err != nil {
		return 0, err
	}
	if value == "" {
		return 0, nil
	}
	return strconv.ParseInt(value, 10, 64)
}

func optionalString(raw json.RawMessage) (string, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", nil
	}
	if raw[0] == '"' {
		var value string
		err := json.Unmarshal(raw, &value)
		return value, err
	}
	var number json.Number
	if err := json.Unmarshal(raw, &number); err != nil {
		return "", err
	}
	return number.String(), nil
}
