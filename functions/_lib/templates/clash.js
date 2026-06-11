/**
 * Complete Clash / Mihomo configuration generator.
 *
 * Produces a full, ready-to-use profile: general settings, a DNS block, all of
 * the user's proxies, an ACL4SSR-style group layout, and rule-providers backed
 * by the official Loyalsoldier/clash-rules release. Rules are referenced (not
 * inlined) so the client keeps them continuously up to date from the source.
 */

import { CONTENT_TYPE, PROTOCOL } from "../constants.js";
import { nodeNames, yamlQuote } from "./shared.js";

/** Build the inline YAML mapping for a single proxy, or "" if unsupported. */
function proxyLine(node) {
	const name = yamlQuote(node.name);
	const server = node.server;
	switch (node.protocol) {
		case PROTOCOL.VLESS_REALITY:
			return (
				`  - {name: ${name}, type: vless, server: ${server}, port: ${node.port}, ` +
				`uuid: ${node.uuid}, network: tcp, udp: true, tls: true, flow: ${node.flow}, ` +
				`servername: ${node.sni}, reality-opts: {public-key: ${node.realityPublicKey || "PUBLIC_KEY_MISSING"}, ` +
				`short-id: '${node.realityShortId}'}, client-fingerprint: chrome}`
			);
		case PROTOCOL.VLESS_WS:
			return (
				`  - {name: ${name}, type: vless, server: ${server}, port: 443, uuid: ${node.uuid}, ` +
				`udp: true, tls: true, network: ws, servername: ${node.wsHost}, ` +
				`ws-opts: {path: ${yamlQuote(node.wsPath)}, headers: {Host: ${node.wsHost}, ` +
				`max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}}`
			);
		case PROTOCOL.VMESS_WS:
			return (
				`  - {name: ${name}, type: vmess, server: ${server}, port: 443, uuid: ${node.uuid}, ` +
				`alterId: 0, cipher: auto, udp: true, tls: true, network: ws, servername: ${node.wsHost}, ` +
				`ws-opts: {path: ${yamlQuote(node.wsPath)}, headers: {Host: ${node.wsHost}, ` +
				`max-early-data: 2048, early-data-header-name: Sec-WebSocket-Protocol}}}`
			);
		case PROTOCOL.ANYTLS:
			return (
				`  - {name: ${name}, type: anytls, server: ${server}, port: ${node.port}, ` +
				`password: ${yamlQuote(node.password)}, client-fingerprint: chrome, udp: true, ` +
				`sni: ${yamlQuote(node.sni)}, alpn: [h2, http/1.1], skip-cert-verify: true}`
			);
		case PROTOCOL.SHADOWSOCKS:
			return (
				`  - {name: ${name}, type: ss, server: ${server}, port: ${node.port}, ` +
				`cipher: ${node.method}, password: ${yamlQuote(node.password)}, udp: true}`
			);
		case PROTOCOL.TROJAN:
			return (
				`  - {name: ${name}, type: trojan, server: ${server}, port: ${node.port}, ` +
				`password: ${yamlQuote(node.password)}, client-fingerprint: chrome, udp: true, ` +
				`sni: ${yamlQuote(node.sni)}, alpn: [h2, http/1.1], skip-cert-verify: true}`
			);
		case PROTOCOL.TUIC:
			return (
				`  - {name: ${name}, type: tuic, server: ${server}, port: ${node.port}, ` +
				`uuid: ${node.uuid}, password: ${node.password}, alpn: [h3], disable-sni: false, ` +
				`reduce-rtt: false, udp-relay-mode: native, congestion-controller: bbr, ` +
				`skip-cert-verify: true, sni: ${node.sni}}`
			);
		default:
			return "";
	}
}

/** Render a `proxies:` block, skipping unsupported protocols. */
function proxiesBlock(nodes) {
	const lines = nodes.map(proxyLine).filter(Boolean);
	return lines.length ? `proxies:\n${lines.join("\n")}` : "proxies: []";
}

/** Render one proxy-group with a fixed header plus the proxy name list. */
function group(name, type, names, extra = "") {
	const header = [`  - name: ${name}`, `    type: ${type}`];
	if (extra) {
		header.push(...extra.split("\n").map((line) => `    ${line}`));
	}
	const proxies = names.map((value) => `      - ${yamlQuote(value)}`);
	return [...header, "    proxies:", ...proxies].join("\n");
}

function proxyGroupsBlock(names) {
	// "🎯 全球直连" must stay a leaf selector (DIRECT/REJECT only). If it
	// references "🚀 节点选择" while "🚀 节点选择" also lists "🎯 全球直连",
	// Clash/Mihomo rejects the profile with "loop is detected in ProxyGroup".
	const selectable = ["♻️ 自动选择", "🎯 全球直连", ...names];
	const urlTestExtra =
		"url: 'http://www.gstatic.com/generate_204'\ninterval: 300\ntolerance: 50";
	const groups = [
		group("🚀 节点选择", "select", selectable),
		group("♻️ 自动选择", "url-test", names, urlTestExtra),
		group("🌍 国外媒体", "select", ["🚀 节点选择", "♻️ 自动选择", "🎯 全球直连", ...names]),
		group("📲 电报信息", "select", ["🚀 节点选择", "🎯 全球直连", ...names]),
		group("Ⓜ️ 微软服务", "select", ["🎯 全球直连", "🚀 节点选择", ...names]),
		group("🍎 苹果服务", "select", ["🎯 全球直连", "🚀 节点选择", ...names]),
		group("🎯 全球直连", "select", ["DIRECT", "REJECT"]),
		group("🛑 全球拦截", "select", ["REJECT", "DIRECT"]),
		group("🐟 漏网之鱼", "select", ["🚀 节点选择", "🎯 全球直连", "♻️ 自动选择", ...names]),
	];
	return `proxy-groups:\n${groups.join("\n")}`;
}

/** Loyalsoldier provider definition. behavior is domain/ipcidr/classical. */
function provider(base, name, behavior) {
	const url = `${base}/${name}.txt`;
	return [
		`  ${name}:`,
		"    type: http",
		`    behavior: ${behavior}`,
		`    url: ${yamlQuote(url)}`,
		`    path: ./ruleset/${name}.yaml`,
		"    interval: 86400",
	].join("\n");
}

function ruleProvidersBlock(base) {
	const domain = [
		"reject",
		"icloud",
		"apple",
		"google",
		"proxy",
		"direct",
		"private",
		"gfw",
		"tld-not-cn",
	];
	const ipcidr = ["telegramcidr", "cncidr", "lancidr"];
	const classical = ["applications"];
	const entries = [
		...domain.map((name) => provider(base, name, "domain")),
		...ipcidr.map((name) => provider(base, name, "ipcidr")),
		...classical.map((name) => provider(base, name, "classical")),
	];
	return `rule-providers:\n${entries.join("\n")}`;
}

const RULES = [
	"RULE-SET,applications,🎯 全球直连",
	"RULE-SET,private,🎯 全球直连",
	"RULE-SET,reject,🛑 全球拦截",
	"RULE-SET,icloud,🍎 苹果服务",
	"RULE-SET,apple,🍎 苹果服务",
	"RULE-SET,google,🚀 节点选择",
	"RULE-SET,proxy,🚀 节点选择",
	"RULE-SET,gfw,🚀 节点选择",
	"RULE-SET,tld-not-cn,🚀 节点选择",
	"RULE-SET,telegramcidr,📲 电报信息,no-resolve",
	"RULE-SET,direct,🎯 全球直连",
	"RULE-SET,lancidr,🎯 全球直连,no-resolve",
	"RULE-SET,cncidr,🎯 全球直连,no-resolve",
	"GEOIP,LAN,🎯 全球直连,no-resolve",
	"GEOIP,CN,🎯 全球直连,no-resolve",
	"MATCH,🐟 漏网之鱼",
];

const GENERAL = `port: 7890
socks-port: 7891
mixed-port: 7892
allow-lan: true
mode: rule
log-level: info
ipv6: true
external-controller: 127.0.0.1:9090
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - https://1.1.1.1/dns-query
    - https://dns.google/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN`;

/**
 * Build a complete Clash profile.
 *
 * @param {Array<object>} nodes Normalized nodes.
 * @param {object} config Resolved runtime config.
 * @param {string} [baseTemplate] Optional operator template override. When it
 *   contains the `#SUBFLOW_PROXIES` / `#SUBFLOW_GROUPS` / `#SUBFLOW_RULES`
 *   markers, the generated sections are injected into it; otherwise the built-in
 *   complete skeleton is used.
 */
export function generateClash(nodes, config, baseTemplate) {
	const names = nodeNames(nodes);
	const proxies = proxiesBlock(nodes);
	const groups = proxyGroupsBlock(names);
	const providers = ruleProvidersBlock(config.ruleSources.clashRulesBase);
	const rules = `rules:\n${RULES.map((rule) => `  - ${rule}`).join("\n")}`;

	let body;
	if (baseTemplate && baseTemplate.includes("#SUBFLOW_PROXIES")) {
		body = baseTemplate
			.replace("#SUBFLOW_PROXIES", proxies)
			.replace("#SUBFLOW_GROUPS", groups)
			.replace("#SUBFLOW_PROVIDERS", providers)
			.replace("#SUBFLOW_RULES", rules);
	} else {
		body = [
			`# Subflow profile: ${config.profileName}`,
			GENERAL,
			proxies,
			groups,
			providers,
			rules,
			"",
		].join("\n\n");
	}

	return { contentType: CONTENT_TYPE.YAML, body };
}
