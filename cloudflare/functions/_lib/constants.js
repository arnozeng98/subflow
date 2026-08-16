/**
 * Cloudflare 侧订阅生成器的集中常量定义。
 *
 * 凡是运维人员可能需要调整的值，都会在 `config.js` 中通过环境变量暴露出来；
 * 这里的字面量仅仅是其默认回退值。把它们集中在单一模块里，意味着各个生成器中
 * 不会散落着难以追踪的魔术字符串；这正是“不硬编码配置”在实践中的要求：只有一个
 * 明确的查看位置，且全部可通过 env 覆盖。
 */

// 公共路由约定：用户名是短、不透露业务含义、且对文件系统/URL 安全的。
export const USERNAME_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

// VPS 安全投影与 Cloudflare 节点模型之间的数据契约版本。
export const RAW_PAYLOAD_SCHEMA_VERSION = 1;

// 在格式协商与分发过程中通用的客户端格式规范标识符。
export const FORMAT = Object.freeze({
	CLASH: "clash",
	SINGBOX: "singbox",
	SURGE: "surge",
	QUANTUMULTX: "quantumultx",
	SHADOWROCKET: "shadowrocket",
	UNIVERSAL: "universal",
});

// 协议分类，与随包发布的 sing-box 管理器中的 JQ_DETECT_PROTOCOL 保持一致。
export const PROTOCOL = Object.freeze({
	VLESS_REALITY: "vless-reality",
	VLESS_WS: "vless-ws",
	VMESS_WS: "vmess-ws",
	ANYTLS: "anytls",
	SHADOWSOCKS: "shadowsocks",
	TROJAN: "trojan",
	TUIC: "tuic",
	SOCKS: "socks",
});

// 默认的请求/运行时调优参数。全部可通过 env 覆盖（参见 config.js）。
export const DEFAULTS = Object.freeze({
	REQUEST_TIMEOUT_MS: 8000,
	TEMPLATE_CACHE_TTL_SECONDS: 21600, // 6 小时：模板/规则在上游变化缓慢。
	RAW_PATH_TEMPLATE: "/internal/raw/{user}",
	DEFAULT_FORMAT: FORMAT.UNIVERSAL,
	PROFILE_NAME: "Subflow",
});

/**
 * 官方的、持续维护的规则源。
 *
 * 生成的配置通过各客户端的原生机制（Clash rule-providers、sing-box 远程 rule_set、
 * Surge/QX RULE-SET）引用这些 URL。客户端会直接拉取并刷新它们，因此下发的配置总是
 * 由最新的上游规则支撑，而无需我们自行转存任何内容。每个基础地址都可通过 env 覆盖，
 * 以便运维人员钉定镜像源或版本。
 */
export const RULE_SOURCES = Object.freeze({
	// Loyalsoldier/clash-rules（release 分支）：Clash rule-provider 所需的规则数据。
	CLASH_RULES_BASE: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release",
	// SagerNet 官方面向 sing-box 预编译的规则集（.srs）。
	SINGBOX_GEOSITE_BASE: "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set",
	SINGBOX_GEOIP_BASE: "https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set",
	// blackmatrix7/ios_rule_script：按平台区分的 RULE-SET 列表。
	BLACKMATRIX7_BASE: "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule",
});

// 每种输出格式对应的内容类型。
export const CONTENT_TYPE = Object.freeze({
	YAML: "text/yaml; charset=utf-8",
	JSON: "application/json; charset=utf-8",
	PLAIN: "text/plain; charset=utf-8",
});
