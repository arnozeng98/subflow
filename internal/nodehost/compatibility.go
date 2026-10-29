package nodehost

import (
	"crypto/ecdh"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"strings"
	"time"
)

func scalarText(raw json.RawMessage) (string, error) {
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
		return "", errors.New("invalid scalar user field")
	}
	return number.String(), nil
}

func (u *User) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	if fields == nil {
		return errors.New("null user record")
	}
	type plain User
	copy := map[string]json.RawMessage{}
	for key, value := range fields {
		copy[key] = value
	}
	for _, key := range []string{"quota_gb", "used_up_bytes", "used_down_bytes", "manual_added_bytes", "reset_day", "expire_at"} {
		delete(copy, key)
	}
	remaining, err := json.Marshal(copy)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(remaining, (*plain)(u)); err != nil {
		return err
	}
	u.hasNativeExpiry = fields["expires_at"] != nil && string(fields["expires_at"]) != "null"
	for key, target := range map[string]*int64{"used_up_bytes": &u.Up, "used_down_bytes": &u.Down, "manual_added_bytes": &u.Manual} {
		value, err := scalarText(fields[key])
		if err != nil {
			return err
		}
		if value != "" {
			number, err := strconv.ParseInt(value, 10, 64)
			if err != nil {
				return errors.New("invalid integer user accounting field")
			}
			*target = number
		}
	}
	reset, err := scalarText(fields["reset_day"])
	if err != nil {
		return err
	}
	if reset != "" {
		day, err := strconv.Atoi(reset)
		if err != nil {
			return errors.New("invalid reset day")
		}
		u.ResetDay = day
	}
	u.ExpireAt, err = scalarText(fields["expire_at"])
	if err != nil {
		return err
	}
	if u.ExpireAt == "" {
		u.ExpireAt = "0"
	}
	quota, err := scalarText(fields["quota_gb"])
	if err != nil {
		return err
	}
	if quota != "" {
		u.QuotaGB, err = strconv.ParseFloat(quota, 64)
		if err != nil || math.IsNaN(u.QuotaGB) || math.IsInf(u.QuotaGB, 0) || u.QuotaGB < 0 {
			return errors.New("invalid quota_gb")
		}
	}
	if fields["quota_bytes"] == nil {
		bytes := u.QuotaGB * (1 << 30)
		if bytes > float64(maxSafe) {
			return errors.New("quota exceeds wire ceiling")
		}
		u.QuotaBytes = int64(math.Round(bytes))
	} else if fields["quota_gb"] == nil {
		u.QuotaGB = float64(u.QuotaBytes) / (1 << 30)
	}
	return nil
}

func (u *User) decodeExpiry(location *time.Location) error {
	if u.ExpireAt == "" || u.ExpireAt == "0" {
		u.Expires = 0
		return nil
	}
	if value, err := strconv.ParseInt(u.ExpireAt, 10, 64); err == nil {
		if value < 0 || value > maxSafe {
			return errors.New("invalid expiry timestamp")
		}
		u.Expires = value
		return nil
	}
	for _, format := range []string{time.RFC3339, "2006-01-02 15:04:05", "2006-01-02"} {
		when, err := time.ParseInLocation(format, u.ExpireAt, location)
		if err == nil {
			if format == "2006-01-02" {
				when = when.AddDate(0, 0, 1)
			}
			u.Expires = when.Unix()
			return nil
		}
	}
	return errors.New("expire_at must be zero, Unix seconds, RFC3339, or a local calendar date")
}

func credentialIdentity(credential Object) string {
	if name := text(credential["name"]); name != "" {
		return name
	}
	return text(credential["username"])
}

func credentialsFor(u *User, tag string) []Object {
	result := []Object{}
	if primary := u.Credentials[tag]; primary != nil {
		result = append(result, primary)
	}
	return append(result, u.CredentialAliases[tag]...)
}

func (h *host) credentialOwners() map[string]string {
	owners := map[string]string{}
	for name, u := range h.db.Users {
		for tag := range u.Credentials {
			for _, credential := range credentialsFor(u, tag) {
				owners[credentialIdentity(credential)] = name
			}
		}
	}
	return owners
}

// Hydrate only public-contract identities present in the supplied configuration.
// Do not rename SOCKS logins, regenerate UUID/passwords, or copy global balances
// into a central grant. Database policy remains authoritative after enrollment.
func (h *host) hydrateCredentials(force bool) error {
	existing := map[string]bool{}
	inferNodes := map[string]bool{}
	for name, u := range h.db.Users {
		inferNodes[name] = u.Nodes == nil && !h.managed()
		if name == "admin" && inferNodes[name] {
			u.Nodes = []string{"*"}
		}
		for tag := range u.Credentials {
			existing[name+"\x00"+tag] = !force
		}
	}
	cleared := map[string]bool{}
	for _, raw := range list(h.config["inbounds"]) {
		in := object(raw)
		tag := text(in["tag"])
		if !validName(tag) {
			return errors.New("inbound tag is required for credential import")
		}
		meta := h.meta[tag]
		if meta.Protocol == "" {
			meta.Protocol = text(in["type"])
			if text(object(in["transport"])["type"]) == "ws" {
				meta.Protocol += "-ws"
			}
			if reality := object(object(in["tls"])["reality"]); reality["enabled"] == true {
				meta.Protocol = "vless-reality"
				if meta.PublicKey == "" {
					private, err := base64.RawURLEncoding.DecodeString(text(reality["private_key"]))
					if err != nil {
						return errors.New("invalid imported Reality private key")
					}
					key, err := ecdh.X25519().NewPrivateKey(private)
					if err != nil {
						return errors.New("invalid imported Reality private key")
					}
					meta.PublicKey = base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes())
				}
			}
		}
		h.meta[tag] = meta
		for _, rawCredential := range list(in["users"]) {
			credential := object(rawCredential)
			identity := credentialIdentity(credential)
			if strings.HasPrefix(identity, "disabled-") {
				continue
			}
			if identity == "" {
				return errors.New("imported credentials require a name or username")
			}
			name := "admin"
			if position := strings.IndexByte(identity, '@'); position >= 0 {
				name = identity[position+1:]
			}
			if !validName(name) {
				return errors.New("imported identity has an invalid business username")
			}
			u := h.db.Users[name]
			if u == nil {
				if h.managed() {
					continue
				}
				u = &User{Enabled: true, ExpireAt: "0", Credentials: map[string]Object{}, CredentialAliases: map[string][]Object{}}
				h.db.Users[name] = u
				inferNodes[name] = true
			}
			if u.Credentials == nil {
				u.Credentials = map[string]Object{}
			}
			if u.CredentialAliases == nil {
				u.CredentialAliases = map[string][]Object{}
			}
			if inferNodes[name] && !contains(u.Nodes, tag) {
				u.Nodes = append(u.Nodes, tag)
			}
			key := name + "\x00" + tag
			if existing[key] {
				continue
			}
			if force && !cleared[key] {
				delete(u.Credentials, tag)
				delete(u.CredentialAliases, tag)
				cleared[key] = true
			}
			if u.Credentials[tag] == nil {
				u.Credentials[tag] = clone(credential)
			} else {
				u.CredentialAliases[tag] = append(u.CredentialAliases[tag], clone(credential))
			}
		}
	}
	return nil
}
