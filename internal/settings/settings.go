package settings

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata"

	"github.com/arnozeng98/subflow/configs"
)

type Config struct {
	ListenHost           string
	ListenPort           int
	APIToken             string
	ConfigPath           string
	UserDBPath           string
	MetaPath             string
	PublicIP             string
	VlessWSDomain        string
	VmessWSDomain        string
	IncludeDisabledUsers bool
	LockPath             string
	BusinessTimezone     string
}

func (c Config) Address() string {
	return net.JoinHostPort(c.ListenHost, strconv.Itoa(c.ListenPort))
}

func Defaults() (Config, error) {
	var d struct {
		Paths struct {
			Config string `json:"singbox_config"`
			UserDB string `json:"user_db"`
			Meta   string `json:"meta"`
			Lock   string `json:"lock"`
		} `json:"paths"`
		API struct {
			Host string `json:"listen_host"`
			Port int    `json:"listen_port"`
		} `json:"data_api"`
		Timezone string `json:"business_timezone"`
	}
	if err := json.Unmarshal(configs.Defaults, &d); err != nil {
		return Config{}, fmt.Errorf("embedded defaults: %w", err)
	}
	return Config{
		ListenHost: d.API.Host, ListenPort: d.API.Port,
		ConfigPath: d.Paths.Config, UserDBPath: d.Paths.UserDB,
		MetaPath: d.Paths.Meta,
		LockPath: d.Paths.Lock, BusinessTimezone: d.Timezone,
	}, nil
}

func Load() (Config, error) {
	return FromLookup(os.LookupEnv)
}

func FromLookup(lookup func(string) (string, bool)) (Config, error) {
	c, err := Defaults()
	if err != nil {
		return c, err
	}
	for name, target := range map[string]*string{
		"SUBFLOW_LISTEN_HOST":       &c.ListenHost,
		"SUBFLOW_API_TOKEN":         &c.APIToken,
		"SUBFLOW_CONFIG_PATH":       &c.ConfigPath,
		"SUBFLOW_USER_DB_PATH":      &c.UserDBPath,
		"SUBFLOW_META_PATH":         &c.MetaPath,
		"SUBFLOW_PUBLIC_IP":         &c.PublicIP,
		"SUBFLOW_WS_DOMAIN":         &c.VlessWSDomain,
		"SUBFLOW_VMESS_WS_DOMAIN":   &c.VmessWSDomain,
		"SUBFLOW_LOCK_PATH":         &c.LockPath,
		"SUBFLOW_BUSINESS_TIMEZONE": &c.BusinessTimezone,
	} {
		if value, ok := lookup(name); ok && strings.TrimSpace(value) != "" {
			*target = strings.TrimSpace(value)
		}
	}
	if raw, ok := lookup("SUBFLOW_LISTEN_PORT"); ok && strings.TrimSpace(raw) != "" {
		c.ListenPort, err = strconv.Atoi(strings.TrimSpace(raw))
		if err != nil {
			return c, fmt.Errorf("SUBFLOW_LISTEN_PORT must be an integer: %w", err)
		}
	}
	if c.ListenPort < 1 || c.ListenPort > 65535 {
		return c, errors.New("SUBFLOW_LISTEN_PORT must be between 1 and 65535")
	}
	if raw, ok := lookup("SUBFLOW_INCLUDE_DISABLED_USERS"); ok {
		switch strings.ToLower(strings.TrimSpace(raw)) {
		case "1", "true", "yes", "on":
			c.IncludeDisabledUsers = true
		case "0", "false", "no", "off", "":
			c.IncludeDisabledUsers = false
		default:
			return c, errors.New("SUBFLOW_INCLUDE_DISABLED_USERS must be a boolean")
		}
	}
	if _, err := time.LoadLocation(c.BusinessTimezone); err != nil {
		return c, fmt.Errorf("SUBFLOW_BUSINESS_TIMEZONE: %w", err)
	}
	return c, nil
}

// ReadEnv accepts literal KEY=value assignments, never shell commands or expansions.
func ReadEnv(r io.Reader) (map[string]string, error) {
	values := make(map[string]string)
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	line := 0
	for scanner.Scan() {
		line++
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		key, value, ok := strings.Cut(text, "=")
		key = strings.TrimSpace(key)
		if !ok || !validKey(key) {
			return nil, fmt.Errorf("environment line %d: expected KEY=value", line)
		}
		value = strings.TrimSpace(value)
		if len(value) > 0 && (value[0] == '"' || value[0] == '\'') {
			if len(value) < 2 || value[len(value)-1] != value[0] {
				return nil, fmt.Errorf("environment line %d: unterminated quote", line)
			}
			value = value[1 : len(value)-1]
		}
		if strings.ContainsAny(value, "\x00\r\n") {
			return nil, fmt.Errorf("environment line %d: invalid value", line)
		}
		if _, exists := values[key]; exists {
			return nil, fmt.Errorf("environment line %d: duplicate key %s", line, key)
		}
		values[key] = value
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read environment: %w", err)
	}
	return values, nil
}

func validKey(key string) bool {
	for i, r := range key {
		if r != '_' && (r < 'A' || r > 'Z') && (r < 'a' || r > 'z') &&
			(i == 0 || r < '0' || r > '9') {
			return false
		}
	}
	return key != ""
}

func LoadEnvFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	values, err := ReadEnv(f)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	for key, value := range values {
		if _, exists := os.LookupEnv(key); !exists {
			if err := os.Setenv(key, value); err != nil {
				return fmt.Errorf("set environment %s: %w", key, err)
			}
		}
	}
	return nil
}
