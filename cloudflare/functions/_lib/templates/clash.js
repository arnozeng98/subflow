/**
 * 完整的 Clash / Mihomo 配置生成器。
 *
 * 生成一份可直接使用的完整配置：基础设置、DNS 区块、用户的全部代理节点、
 * ACL4SSR 风格的策略组布局，以及由官方 Loyalsoldier/clash-rules 发行版
 * 支撑的 rule-providers（规则提供方）。规则采用引用方式（而非内联写死），
 * 这样客户端就能持续从上游源同步、保持规则最新。
 */

import { CONTENT_TYPE, PROTOCOL } from "../constants.js";
import { nodeNames, yamlQuote } from "./shared.js";

/** 为单个代理节点构造内联的 YAML 映射；若协议不受支持则返回 ""。 */
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

/** 渲染整个 `proxies:` 区块，跳过不受支持的协议。 */
function proxiesBlock(nodes) {
	const lines = nodes.map(proxyLine).filter(Boolean);
	return lines.length ? `proxies:\n${lines.join("\n")}` : "proxies: []";
}

/** 渲染单个 proxy-group（策略组）：固定的头部字段加上代理名称列表。 */
function group(name, type, names, extra = "") {
	const header = [`  - name: ${name}`, `    type: ${type}`];
	if (extra) {
		header.push(...extra.split("\n").map((line) => `    ${line}`));
	}
	const proxies = names.map((value) => `      - ${yamlQuote(value)}`);
	return [...header, "    proxies:", ...proxies].join("\n");
}

function proxyGroupsBlock(names) {
	// "🎯 全球直连" 必须保持为叶子选择器（仅包含 DIRECT/REJECT）。如果它
	// 引用了 "🚀 节点选择"，而 "🚀 节点选择" 同时又列出了 "🎯 全球直连"，
	// 就会形成循环引用，Clash/Mihomo 会以 "loop is detected in ProxyGroup"
	// 报错并拒绝该配置。
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

/** 生成单条 Loyalsoldier rule-provider 定义；behavior 取值为 domain/ipcidr/classical。 */
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
 * 构建一份完整的 Clash 配置。
 *
 * @param {Array<object>} nodes 已归一化的节点列表。
 * @param {object} config 解析后的运行时配置。
 * @param {string} [baseTemplate] 可选的运营方自定义模板覆盖项。当模板中包含
 *   `#SUBFLOW_PROXIES` / `#SUBFLOW_GROUPS` / `#SUBFLOW_RULES` 等占位标记时，
 *   生成的各个区块会被注入到对应位置；否则使用内置的完整骨架。
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
