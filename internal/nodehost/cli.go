package nodehost

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/arnozeng98/subflow/internal/settings"
	"github.com/arnozeng98/subflow/internal/state"
)

const Help = `Subflow 原生节点管理
  init                               初始化/验证配置并启动 sing-box
  config init                        init 的兼容入口；不自动创建协议/选择端口
  maintenance [once|run]              单次本地计量、配额及到期检查
  protocol list
  protocol add --type TYPE --tag TAG --port PORT [--server-name HOST] [--path /ws]
  protocol update --tag TAG [--port PORT] [--server-name HOST] [--path /ws]
  protocol delete --tag TAG
  protocol certificate --tag TAG      仅导出公开 PEM 证书（不含私钥）
  protocol acme --tag TAG --domain HOST --email EMAIL --token-file FILE
                [--acme-mode auto|inline|provider] [--ca letsencrypt|zerossl]
  protocol certificate-import --tag TAG --cert-file FILE --key-file FILE
                              [--server-name HOST]
    TYPE: vless-reality,vless-ws,vmess-ws,anytls,trojan,tuic,shadowsocks,socks
  user list
  user add --name NAME [--nodes tag1,tag2|*] [--quota-bytes N] [--expires UNIX]
           [--reset-day 0..32]
  user update --name NAME [--enabled true|false] [--nodes tag1,tag2|*]
              [--quota-bytes N] [--expires UNIX] [--reset-day 0..32] [--reset-usage]
  user renew --name NAME --days N|--expires UNIX [--quota-bytes N] [--reset-usage]
  user usage --name NAME
  user correct --name NAME [--up-bytes N] [--down-bytes N]
  user delete --name NAME
  user reset --name NAME             独立节点重置流量（admin 无流量/配额）
    reset-day: 0 手动；1..31 按本地月份截到有效日；32 月末；补处理错过的日期
  status                             本地状态（不输出密钥）
  relay set --host HOST --port PORT [--username USER --password-file FILE] [--full]
  relay off
  relay rule-add --tag TAG --file PATH [--outbound relay|warp]
  relay rule-delete --tag TAG
  warp set --host HOST --port PORT [--username USER --password-file FILE] [--full]
  warp off                           使用已有 WARP SOCKS 端点，不下载远程安装脚本
  export --name NAME --format json|uri|clash
  config check
  config apply --file FILE            只允许独立模式；重新生成身份/权限/统计规则
  config recover                     崩溃恢复：停止不确定的运行时并保留流量记录
  system start|restart|stop|enable|disable|status
  system prepare-restart             先计量再停核，持久暂停；升级后 system start 恢复
  agent enroll --url https://HOST --token-file FILE
  agent sync
  agent run                          5 秒计量/配额执行，60 秒中央同步
  sync                               独立模式执行维护；已注册时同步中央
  service ACTION                     system ACTION 的别名
  node ACTION ...                    protocol ACTION ... 的别名
  help

无参数启动中文编号菜单；子菜单接受上述完整命令。托管模式禁止本地用户、
配额和原始配置修改。日历使用 SUBFLOW_BUSINESS_TIMEZONE；用户凭据不因续期/重置而改变。
自签名证书只用于引导，不代表生产 TLS；生产请配置 ACME DNS-01 或导入受信任证书。
Cloudflare token 仅从文件导入并保存在受保护状态，Raw 不导出；ACME 续期由内核负责。
需 Debian/systemd、sing-box（with_v2ray_api；ACME 另需 with_acme）；不执行远程安装器。
`

func Run(ctx context.Context, args []string, in io.Reader, out, errOut io.Writer) error {
	c, err := settings.Load()
	if err != nil {
		return err
	}
	return RunWithOptions(ctx, args, in, out, errOut, Options{Config: c})
}

func RunWithOptions(ctx context.Context, args []string, in io.Reader, out, errOut io.Writer, opts Options) error {
	h := newHost(opts, out, errOut)
	if len(args) == 0 {
		return h.menu(ctx, in)
	}
	return h.run(ctx, args)
}

func (h *host) menu(ctx context.Context, in io.Reader) error {
	if in == nil {
		return errors.New("interactive input required")
	}
	scan := bufio.NewScanner(in)
	for {
		fmt.Fprintln(h.out, "1. 协议管理\n2. 用户管理\n3. 节点状态\n4. 中转管理\n5. WARP 管理\n6. 订阅导出\n7. 系统管理\n0. 退出")
		if !scan.Scan() {
			return scan.Err()
		}
		line := strings.TrimSpace(scan.Text())
		if line == "0" {
			return nil
		}
		if line == "3" {
			if err := h.run(ctx, []string{"status"}); err != nil {
				fmt.Fprintln(h.errOut, err)
			}
			continue
		}
		if line == "1" || line == "2" || line == "4" || line == "5" || line == "6" || line == "7" {
			fmt.Fprint(h.out, Help)
			fmt.Fprintln(h.out, "输入完整命令：")
			if !scan.Scan() {
				return scan.Err()
			}
			line = scan.Text()
		}
		args, err := splitCommand(line)
		if err == nil && len(args) > 0 {
			err = h.run(ctx, args)
		}
		if err != nil {
			fmt.Fprintln(h.errOut, "错误:", err)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
}

func splitCommand(s string) ([]string, error) {
	var args []string
	var b strings.Builder
	var quote rune
	started := false
	for _, r := range s {
		if quote != 0 {
			if r == quote {
				quote = 0
			} else {
				b.WriteRune(r)
			}
			continue
		}
		switch r {
		case '\'', '"':
			quote = r
			started = true
		case ' ', '\t':
			if started {
				args = append(args, b.String())
				b.Reset()
				started = false
			}
		default:
			b.WriteRune(r)
			started = true
		}
	}
	if quote != 0 {
		return nil, errors.New("unterminated quote")
	}
	if started {
		args = append(args, b.String())
	}
	return args, nil
}

func (h *host) flags(name string) *flag.FlagSet {
	f := flag.NewFlagSet(name, flag.ContinueOnError)
	f.SetOutput(h.errOut)
	return f
}
func parseFlags(f *flag.FlagSet, args []string) error {
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	return nil
}
func (h *host) print(v any) error {
	e := json.NewEncoder(h.out)
	e.SetIndent("", "  ")
	return e.Encode(v)
}

func (h *host) run(ctx context.Context, args []string) error {
	switch args[0] {
	case "node":
		if len(args) == 1 {
			return h.protocolCLI(ctx, []string{"list"})
		}
		return h.protocolCLI(ctx, args[1:])
	case "service":
		return h.run(ctx, append([]string{"system"}, args[1:]...))
	case "sync":
		if len(args) != 1 {
			return errors.New("sync accepts no arguments")
		}
		enrolled := false
		if err := h.locked(ctx, func() error { enrolled = h.central.ServerID != ""; return nil }); err != nil {
			return err
		}
		if enrolled {
			return h.sync(ctx)
		}
		return h.enforce(ctx)
	case "help", "--help", "-h":
		fmt.Fprint(h.out, Help)
		return nil
	case "init":
		return h.locked(ctx, func() error { return h.mutate(ctx, func() error { return nil }) })
	case "maintenance":
		if len(args) > 2 || len(args) == 2 && (args[1] != "once" && args[1] != "run") {
			return errors.New("maintenance accepts only once|run")
		}
		return h.enforce(ctx)
	case "protocol":
		return h.protocolCLI(ctx, args[1:])
	case "user":
		return h.userCLI(ctx, args[1:])
	case "status":
		return h.locked(ctx, func() error {
			return h.print(Object{"managed": h.managed(), "server_id": h.central.ServerID, "applied_revision": h.central.AppliedRevision, "stats_blocked": h.db.StatsBlocked, "runtime_stopped": h.db.RuntimeStopped, "restart_prepared": h.db.RestartPrepared, "probe_required": h.db.ProbeRequired, "uncertain_periods": h.db.Uncertain, "protocols": len(list(h.config["inbounds"])), "users": len(h.db.Users)})
		})
	case "relay", "warp":
		return h.routingCLI(ctx, args[0], args[1:])
	case "export":
		f := h.flags("export")
		name := f.String("name", "admin", "username")
		format := f.String("format", "json", "json|uri|clash")
		if err := parseFlags(f, args[1:]); err != nil {
			return err
		}
		if *format != "json" && *format != "uri" && *format != "clash" {
			return errors.New("unknown export format")
		}
		return h.locked(ctx, func() error {
			p, err := h.payload(*name)
			if err != nil {
				return err
			}
			switch *format {
			case "json":
				return h.print(p)
			case "clash":
				config, err := h.clash(p)
				if err != nil {
					return err
				}
				return h.print(config)
			case "uri":
				for _, in := range p.Inbounds {
					for _, credential := range list(in["users"]) {
						record := clone(in)
						record["users"] = []any{credential}
						uri, e := URI(p, record)
						if e != nil {
							return e
						}
						fmt.Fprintln(h.out, uri)
					}
				}
				return nil
			default:
				return errors.New("unknown export format")
			}
		})
	case "config":
		return h.configCLI(ctx, args[1:])
	case "system":
		if len(args) != 2 {
			return errors.New("system requires one action")
		}
		err := h.locked(ctx, func() error {
			switch args[1] {
			case "start", "restart":
				h.allowPrepared = true
				defer func() { h.allowPrepared = false }()
				return h.mutate(ctx, func() error { h.db.RestartPrepared = false; h.db.ProbeRequired = true; return nil })
			case "prepare-restart":
				return h.prepareRestart(ctx)
			case "stop":
				if err := h.sample(ctx); err != nil {
					return err
				}
				if err := h.command(ctx, "stop"); err != nil {
					return err
				}
				h.db.RuntimeStopped = true
				h.db.Counters = map[string]int64{}
				return state.WriteJSON(h.opts.Config.UserDBPath, h.db)
			case "enable", "disable":
				return h.command(ctx, args[1])
			case "status":
				b, err := h.execute(ctx, "systemctl", "show", "sing-box.service", "--property=ActiveState,SubState")
				fmt.Fprint(h.out, string(b))
				return err
			default:
				return errors.New("invalid system action")
			}
		})
		if err == nil && (args[1] == "start" || args[1] == "restart") {
			return h.enforce(ctx)
		}
		return err
	case "agent":
		if len(args) < 2 {
			return errors.New("agent requires enroll|sync|run")
		}
		switch args[1] {
		case "enroll":
			f := h.flags("agent enroll")
			raw := f.String("url", "", "HTTPS origin")
			token := f.String("token-file", "", "one-time token")
			if err := parseFlags(f, args[2:]); err != nil {
				return err
			}
			return h.enroll(ctx, *raw, *token)
		case "sync":
			if len(args) != 2 {
				return errors.New("unexpected arguments")
			}
			return h.sync(ctx)
		case "run":
			if len(args) != 2 {
				return errors.New("unexpected arguments")
			}
			return h.agentRun(ctx)
		}
	}
	return errors.New("unknown command; use help")
}

func (h *host) protocolCLI(ctx context.Context, args []string) error {
	if len(args) < 1 {
		return errors.New("protocol requires action")
	}
	f := h.flags("protocol")
	typ := f.String("type", "", "protocol")
	tag := f.String("tag", "", "tag")
	port := f.Int("port", 0, "port")
	server := f.String("server-name", "", "TLS hostname")
	path := f.String("path", "", "WebSocket path")
	domain := f.String("domain", "", "ACME DNS hostname")
	email := f.String("email", "", "ACME account email")
	tokenFile := f.String("token-file", "", "Cloudflare API token file")
	acmeMode := f.String("acme-mode", "auto", "auto|inline|provider")
	ca := f.String("ca", "letsencrypt", "letsencrypt|zerossl")
	certFile := f.String("cert-file", "", "PEM certificate chain")
	keyFile := f.String("key-file", "", "PEM private key")
	if err := parseFlags(f, args[1:]); err != nil {
		return err
	}
	return h.locked(ctx, func() error {
		if args[0] == "list" {
			inventory := []Object{}
			for _, v := range list(h.config["inbounds"]) {
				in := object(v)
				entry := project(in, "tag", "type", "listen_port")
				entry["protocol"] = h.meta[text(in["tag"])].Protocol
				entry["tls_mode"] = h.meta[text(in["tag"])].TLSMode
				inventory = append(inventory, entry)
			}
			return h.print(inventory)
		}
		if args[0] == "certificate" {
			for _, v := range list(h.config["inbounds"]) {
				in := object(v)
				if text(in["tag"]) == *tag {
					cert := list(object(in["tls"])["certificate"])
					if len(cert) == 0 {
						return errors.New("protocol has no local certificate")
					}
					for _, line := range cert {
						fmt.Fprint(h.out, text(line))
					}
					return nil
				}
			}
			return errors.New("protocol not found")
		}
		h.editWhilePrepared = true
		defer func() { h.editWhilePrepared = false }()
		return h.mutate(ctx, func() error {
			if args[0] == "acme" {
				return h.configureACME(ctx, *tag, *domain, *email, *tokenFile, *acmeMode, *ca)
			}
			if args[0] == "certificate-import" {
				return h.importCertificate(*tag, *server, *certFile, *keyFile)
			}
			if args[0] == "add" {
				return h.addProtocol(*typ, *tag, *port, *server, *path)
			}
			inbounds := list(h.config["inbounds"])
			for i, v := range inbounds {
				in := object(v)
				if text(in["tag"]) != *tag {
					continue
				}
				switch args[0] {
				case "delete":
					h.config["inbounds"] = append(inbounds[:i], inbounds[i+1:]...)
					delete(h.meta, *tag)
					for _, u := range h.db.Users {
						delete(u.Credentials, *tag)
						delete(u.CredentialAliases, *tag)
					}
					return nil
				case "update":
					if *port != 0 {
						if *port < 1 || *port > 65535 {
							return errors.New("invalid port")
						}
						for _, other := range inbounds {
							if text(object(other)["tag"]) != *tag && number(object(other)["listen_port"]) == int64(*port) {
								return errors.New("port already exists")
							}
						}
						in["listen_port"] = *port
					}
					if *path != "" {
						if text(object(in["transport"])["type"]) != "ws" || !strings.HasPrefix(*path, "/") {
							return errors.New("invalid WS path")
						}
						object(in["transport"])["path"] = *path
					}
					if *server != "" {
						tls := object(in["tls"])
						if len(tls) == 0 {
							return errors.New("protocol does not use TLS")
						}
						if reality := object(tls["reality"]); len(reality) > 0 {
							tls["server_name"] = *server
							object(reality["handshake"])["server"] = *server
						} else {
							if !h.canRegenerateCertificate(in) {
								return errors.New("production TLS name changes require protocol acme or certificate-import")
							}
							replacement, e := certificate(*server, h.opts.Now())
							if e != nil {
								return e
							}
							if a, ok := tls["alpn"]; ok {
								replacement["alpn"] = a
							}
							in["tls"] = replacement
						}
					}
					return nil
				default:
					return errors.New("invalid protocol action")
				}
			}
			return errors.New("protocol not found")
		})
	})
}

func (h *host) userCLI(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("user requires action")
	}
	f := h.flags("user")
	name := f.String("name", "", "username")
	enabled := f.String("enabled", "", "true|false")
	nodes := f.String("nodes", "", "tag1,tag2|*")
	quota := f.Int64("quota-bytes", -1, "quota, zero unlimited standalone")
	expires := f.Int64("expires", -1, "expiration unix seconds")
	resetDay := f.Int("reset-day", -1, "0 manual, 1-31 monthly clamped, 32 month-end")
	days := f.Int("days", 0, "renewal days")
	reset := f.Bool("reset-usage", false, "reset usage on renewal/update")
	up := f.Int64("up-bytes", -1, "corrected cumulative uplink")
	down := f.Int64("down-bytes", -1, "corrected cumulative downlink")
	if err := parseFlags(f, args[1:]); err != nil {
		return err
	}
	return h.locked(ctx, func() error {
		if args[0] == "usage" {
			if !validName(*name) || h.db.Users[*name] == nil {
				return errors.New("user not found")
			}
			if err := h.sample(ctx); err != nil {
				return err
			}
			u := h.db.Users[*name]
			next, err := h.nextReset(u)
			if err != nil {
				return err
			}
			return h.print(Object{"username": *name, "up": u.Up, "down": u.Down, "manual_added_bytes": u.Manual, "quota_bytes": u.QuotaBytes, "reset_day": u.ResetDay, "next_reset_at": next, "expires_at": u.Expires})
		}
		if args[0] == "list" {
			rows := []Object{}
			for _, n := range sortedUsers(h.db) {
				u := h.db.Users[n]
				rows = append(rows, Object{"username": n, "enabled": u.Enabled, "quota_bytes": u.QuotaBytes, "up": u.Up, "down": u.Down, "nodes": u.Nodes, "expires_at": u.Expires, "reset_day": u.ResetDay})
			}
			return h.print(rows)
		}
		if h.managed() {
			return errors.New("central policy forbids local user/quota changes")
		}
		if !validName(*name) {
			return errors.New("invalid username")
		}
		if *resetDay < -1 || *resetDay > 32 || *days < 0 || *days > 36500 || *up < -1 || *up > maxSafe || *down < -1 || *down > maxSafe || *quota < -1 || *expires < -1 {
			return errors.New("invalid user quota, renewal, correction or reset-day")
		}
		if *name == "admin" && (*quota >= 0 || *resetDay >= 0 || *reset || args[0] == "reset" || args[0] == "delete" || args[0] == "renew" || args[0] == "correct") {
			return errors.New("admin cannot have quota, reset or deletion")
		}
		return h.mutate(ctx, func() error {
			now, err := h.localNow()
			if err != nil {
				return err
			}
			u := h.db.Users[*name]
			switch args[0] {
			case "add":
				if u != nil {
					return errors.New("user exists")
				}
				u = &User{Enabled: true, Nodes: []string{"*"}, ExpireAt: "0", Credentials: map[string]Object{}}
				h.db.Users[*name] = u
			case "update":
				if u == nil {
					return errors.New("user not found")
				}
			case "renew":
				if u == nil {
					return errors.New("user not found")
				}
				if *days == 0 && *expires < 0 {
					return errors.New("renew requires --days or --expires")
				}
				if *days > 0 && *expires >= 0 {
					return errors.New("choose either --days or --expires")
				}
				if *days > 0 {
					base := now
					if u.Expires > now.Unix() {
						base = time.Unix(u.Expires, 0).In(now.Location())
					}
					u.Expires = base.AddDate(0, 0, *days).Unix()
					if u.Expires > maxSafe {
						return errors.New("renewed expiration exceeds safe integer")
					}
					u.ExpireAt = strconv.FormatInt(u.Expires, 10)
				}
				u.Enabled = true
			case "correct":
				if u == nil {
					return errors.New("user not found")
				}
				if *up < 0 && *down < 0 {
					return errors.New("correct requires --up-bytes or --down-bytes")
				}
				if u.Period >= maxSafe {
					return errors.New("period exhausted")
				}
				if *up >= 0 {
					u.Up = *up
				}
				if *down >= 0 {
					u.Down = *down
				}
				u.Manual = 0
				u.Period++
			case "delete":
				if u == nil {
					return errors.New("user not found")
				}
				u.Enabled = false
				u.Nodes = []string{}
				return nil
			case "reset":
				if u == nil {
					return errors.New("user not found")
				}
				if err := resetUsage(u, now); err != nil {
					return err
				}
			default:
				return errors.New("invalid user action")
			}
			if *reset && args[0] != "reset" {
				if err := resetUsage(u, now); err != nil {
					return err
				}
			}
			if *resetDay >= 0 {
				u.ResetDay = *resetDay
				u.ResetAnchor = now.Unix()
			}
			if *enabled != "" {
				v, e := strconv.ParseBool(*enabled)
				if e != nil {
					return errors.New("invalid enabled boolean")
				}
				u.Enabled = v
			}
			if *nodes != "" {
				a := strings.Split(*nodes, ",")
				for _, tag := range a {
					if tag != "*" && !validName(tag) {
						return errors.New("invalid node permission")
					}
				}
				u.Nodes = a
			}
			if *quota >= 0 {
				if *quota > maxSafe {
					return errors.New("quota exceeds safe integer")
				}
				u.QuotaBytes = *quota
				u.QuotaGB = float64(*quota) / (1 << 30)
			}
			if *expires >= 0 {
				if *expires > maxSafe {
					return errors.New("expiration exceeds safe integer")
				}
				u.Expires = *expires
				u.ExpireAt = strconv.FormatInt(*expires, 10)
			}
			return nil
		})
	})
}

func (h *host) routingCLI(ctx context.Context, kind string, args []string) error {
	if len(args) == 0 {
		return errors.New("routing requires action")
	}
	f := h.flags(kind)
	hostName := f.String("host", "", "SOCKS host")
	port := f.Int("port", 0, "SOCKS port")
	username := f.String("username", "", "SOCKS username")
	passwordFile := f.String("password-file", "", "SOCKS password file")
	full := f.Bool("full", false, "route all authorized traffic")
	tag := f.String("tag", "", "rule set tag")
	path := f.String("file", "", "local source rule-set JSON")
	outbound := f.String("outbound", "relay", "relay|warp")
	if err := parseFlags(f, args[1:]); err != nil {
		return err
	}
	return h.locked(ctx, func() error {
		return h.mutate(ctx, func() error {
			switch args[0] {
			case "set":
				if *hostName == "" || *port < 1 || *port > 65535 || strings.ContainsAny(*hostName, "/ \r\n") {
					return errors.New("invalid SOCKS endpoint")
				}
				_ = net.JoinHostPort(*hostName, strconv.Itoa(*port))
				ob := Object{"type": "socks", "tag": kind, "server": *hostName, "server_port": *port, "version": "5"}
				if *username != "" {
					ob["username"] = *username
				}
				if *passwordFile != "" {
					b, e := os.ReadFile(*passwordFile)
					if e != nil {
						return errors.New("cannot read SOCKS password file")
					}
					ob["password"] = strings.TrimSpace(string(b))
				}
				if kind == "relay" {
					h.routing.Relay = ob
				} else {
					h.routing.WARP = ob
				}
				if *full {
					h.routing.Full = kind
				}
			case "off":
				if kind == "relay" {
					h.routing.Relay = nil
				} else {
					h.routing.WARP = nil
				}
				if h.routing.Full == kind {
					h.routing.Full = ""
				}
				rules := []RouteRule{}
				for _, r := range h.routing.Rules {
					if r.Outbound != kind {
						rules = append(rules, r)
					}
				}
				h.routing.Rules = rules
			case "rule-add":
				if !validName(*tag) || !filepath.IsAbs(*path) {
					return errors.New("rule tag and absolute local path required")
				}
				if *outbound != "relay" && *outbound != "warp" {
					return errors.New("invalid rule outbound")
				}
				if *outbound == "relay" && h.routing.Relay == nil || *outbound == "warp" && h.routing.WARP == nil {
					return errors.New("configure SOCKS outbound first")
				}
				var rule Object
				if err := state.ReadJSON(*path, &rule); err != nil {
					return err
				}
				if number(rule["version"]) != 1 && number(rule["version"]) != 2 && number(rule["version"]) != 3 {
					return errors.New("invalid source rule-set version")
				}
				for _, r := range h.routing.Rules {
					if r.Tag == *tag {
						return errors.New("rule tag already exists")
					}
				}
				h.routing.Rules = append(h.routing.Rules, RouteRule{*tag, *path, *outbound})
			case "rule-delete":
				found := false
				rules := []RouteRule{}
				for _, r := range h.routing.Rules {
					if r.Tag == *tag {
						found = true
					} else {
						rules = append(rules, r)
					}
				}
				if !found {
					return errors.New("rule not found")
				}
				h.routing.Rules = rules
			default:
				return errors.New("invalid routing action")
			}
			return nil
		})
	})
}

func (h *host) configCLI(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New("config requires action")
	}
	f := h.flags("config")
	path := f.String("file", "", "configuration file")
	if err := parseFlags(f, args[1:]); err != nil {
		return err
	}
	return h.locked(ctx, func() error {
		switch args[0] {
		case "init":
			return h.mutate(ctx, func() error { return nil })
		case "check":
			if _, err := h.execute(ctx, "sing-box", "check", "-c", h.opts.Config.ConfigPath); err != nil {
				return errors.New("sing-box configuration check failed")
			}
			return nil
		case "recover":
			return nil
		case "apply":
			if h.managed() {
				return errors.New("central policy forbids raw configuration edits")
			}
			h.editWhilePrepared = true
			defer func() { h.editWhilePrepared = false }()
			return h.mutate(ctx, func() error {
				var config Object
				if err := state.ReadJSON(*path, &config); err != nil {
					return err
				}
				if config == nil {
					return errors.New("null config")
				}
				h.config = config
				return h.hydrateCredentials(true)
			})
		default:
			return errors.New("invalid config action")
		}
	})
}
