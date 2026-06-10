/**
 * Centralized constants for the Cloudflare-side subscription generator.
 *
 * Every value that could conceivably be tuned by an operator is exposed through
 * an environment variable in `config.js`; the literals here are only the
 * fallback defaults. Keeping them in one module means there are no magic strings
 * scattered across the generators, which is what "no hard-coded config" requires
 * in practice: one obvious place to look, all of it overridable via env.
 */

// Public route contract: usernames are short, opaque, filesystem/URL safe.
export const USERNAME_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

// Canonical client format identifiers used across negotiation and dispatch.
export const FORMAT = Object.freeze({
	CLASH: "clash",
	SINGBOX: "singbox",
	SURGE: "surge",
	QUANTUMULTX: "quantumultx",
	SHADOWROCKET: "shadowrocket",
	UNIVERSAL: "universal",
});

// Upstream protocol categories, mirrored from Tangfffyx/sing-box JQ_DETECT_PROTOCOL.
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

// Default request/runtime tuning. All overridable via env (see config.js).
export const DEFAULTS = Object.freeze({
	REQUEST_TIMEOUT_MS: 8000,
	TEMPLATE_CACHE_TTL_SECONDS: 21600, // 6h: templates/rules change slowly upstream.
	RAW_PATH_TEMPLATE: "/internal/raw/{user}",
	DEFAULT_FORMAT: FORMAT.UNIVERSAL,
	PROFILE_NAME: "Subflow",
});

/**
 * Official, continuously-maintained rule sources.
 *
 * Generated configs reference these URLs through native mechanisms
 * (Clash rule-providers, sing-box remote rule_set, Surge/QX RULE-SET). The
 * client fetches and refreshes them directly, so the delivered configuration is
 * always backed by the latest upstream rules without us re-hosting anything.
 * Each base is overridable via env so an operator can pin a mirror or version.
 */
export const RULE_SOURCES = Object.freeze({
	// Loyalsoldier/clash-rules (release branch): Clash rule-provider payloads.
	CLASH_RULES_BASE: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release",
	// SagerNet official compiled rule-sets for sing-box (.srs).
	SINGBOX_GEOSITE_BASE: "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set",
	SINGBOX_GEOIP_BASE: "https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set",
	// blackmatrix7/ios_rule_script: per-platform RULE-SET lists.
	BLACKMATRIX7_BASE: "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule",
});

// Content types per output format.
export const CONTENT_TYPE = Object.freeze({
	YAML: "text/yaml; charset=utf-8",
	JSON: "application/json; charset=utf-8",
	PLAIN: "text/plain; charset=utf-8",
});
